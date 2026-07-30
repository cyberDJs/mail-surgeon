import CryptoKit
import Foundation

struct MailIndexingService: Sendable {
  private let factory = ConnectorFactory()
  private let parser = MailMessageParser()

  func buildIndex(
    for source: MailSourceDescriptor,
    store: MailIndexStore,
    batchSize: Int = 100,
    progress: (@MainActor @Sendable (MailIndexProgress) -> Void)? = nil
  ) async throws {
    let fingerprint = try Self.fingerprint(for: source)
    try store.beginIndexing(source: source, fingerprint: fingerprint)

    let connector = factory.makeConnector(for: source)
    try await connector.validateAccess()

    var batch: [IndexedMessageEntry] = []
    var indexedCount = 0
    var bytesIndexed: Int64 = 0

    do {
      for try await record in connector.scanMessages() {
        try Task.checkCancellation()
        let entry = try await indexedEntry(from: record)
        batch.append(entry)
        indexedCount += 1
        bytesIndexed += record.byteSize

        if batch.count >= batchSize {
          try store.insertBatch(batch, sourceID: source.id)
          batch.removeAll(keepingCapacity: true)
          try store.updateIndexingProgress(
            sourceID: source.id,
            indexedCount: indexedCount,
            bytesIndexed: bytesIndexed
          )
          await progress?(
            MailIndexProgress(
              status: .indexing,
              indexedMessages: indexedCount,
              bytesIndexed: bytesIndexed,
              databaseSize: store.sizeOnDisk,
              detail: "Indexuji: \(record.folderPath)"
            ))
        }
      }

      if !batch.isEmpty {
        try store.insertBatch(batch, sourceID: source.id)
      }
      try store.updateIndexingProgress(
        sourceID: source.id,
        indexedCount: indexedCount,
        bytesIndexed: bytesIndexed
      )
      try store.finishIndexing(sourceID: source.id, status: .indexed)
      await progress?(
        MailIndexProgress(
          status: .indexed,
          indexedMessages: indexedCount,
          bytesIndexed: bytesIndexed,
          databaseSize: store.sizeOnDisk,
          detail: "Index dokončen."
        ))
    } catch is CancellationError {
      try? store.finishIndexing(
        sourceID: source.id,
        status: .failed,
        error: "Indexing cancelled."
      )
      throw CancellationError()
    } catch {
      try? store.finishIndexing(
        sourceID: source.id,
        status: .failed,
        error: error.localizedDescription
      )
      throw error
    }
  }

  func status(for source: MailSourceDescriptor, store: MailIndexStore) async throws
    -> MailIndexProgress
  {
    let fingerprint = try? Self.fingerprint(for: source)
    return try store.status(source: source, currentFingerprint: fingerprint)
  }

  func deleteIndex(for source: MailSourceDescriptor, store: MailIndexStore) async throws {
    try store.deleteIndex(for: source.id)
  }

  static func fingerprint(for source: MailSourceDescriptor) throws -> SourceFingerprint {
    guard let url = source.location else { throw MailIndexError.missingSourceLocation }
    let fileURLs = try indexableFiles(in: url)
    var totalSize: Int64 = 0
    var newestModificationDate: Date?
    var hasher = SHA256()

    for fileURL in fileURLs {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      let modifiedAt = attributes[.modificationDate] as? Date
      totalSize += fileSize
      if let modifiedAt, newestModificationDate.map({ modifiedAt > $0 }) ?? true {
        newestModificationDate = modifiedAt
      }

      hasher.update(data: Data(fileURL.path.utf8))
      hasher.update(data: Data("\(fileSize)".utf8))
      if let modifiedAt {
        hasher.update(data: Data("\(modifiedAt.timeIntervalSince1970)".utf8))
      }
      try updateHasherWithSample(from: fileURL, hasher: &hasher)
    }

    return SourceFingerprint(
      fileSize: totalSize,
      modificationDate: newestModificationDate,
      lightweightHash: hasher.finalize().map { String(format: "%02x", $0) }.joined()
    )
  }

  private func indexedEntry(from record: MailMessageRecord) async throws -> IndexedMessageEntry {
    guard let location = record.location else {
      throw ConnectorError.accessDenied("Zpráva nemá uložené umístění pro indexaci.")
    }

    return try await Task.detached {
      try Task.checkCancellation()
      let scoped = location.fileURL.startAccessingSecurityScopedResource()
      defer {
        if scoped { location.fileURL.stopAccessingSecurityScopedResource() }
      }

      let handle = try FileHandle(forReadingFrom: location.fileURL)
      defer { try? handle.close() }
      try handle.seek(toOffset: location.byteOffset)
      guard let data = try handle.read(upToCount: Int(location.byteLength)) else {
        throw ConnectorError.unreadableFile(location.fileURL.lastPathComponent)
      }

      let detail = parser.detail(from: data, sourceIdentifier: record.sourceIdentifier)
      return IndexedMessageEntry(
        record: record,
        previewExcerpt: detail.plainTextPreview ?? "",
        attachments: detail.attachments,
        filePath: location.fileURL.path,
        sourceOffset: location.byteOffset,
        sourceLength: location.byteLength
      )
    }.value
  }

  private static func indexableFiles(in url: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw ConnectorError.missingFile(url.path)
    }

    if !isDirectory.boolValue {
      return [url]
    }

    let bundleFile = url.appendingPathComponent("mbox")
    if FileManager.default.fileExists(atPath: bundleFile.path) {
      return [bundleFile]
    }

    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw ConnectorError.unreadableFile(url.lastPathComponent)
    }

    var files: [URL] = []
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
      guard values.isRegularFile == true, values.isReadable == true else { continue }
      if fileURL.lastPathComponent == "mbox" || fileURL.pathExtension.lowercased() == "mbox" {
        files.append(fileURL)
      }
    }
    return files.sorted { $0.path < $1.path }
  }

  private static func updateHasherWithSample(from url: URL, hasher: inout SHA256) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    if let prefix = try handle.read(upToCount: 4_096) {
      hasher.update(data: prefix)
    }

    let size = try handle.seekToEnd()
    if size > 4_096 {
      try handle.seek(toOffset: max(0, size - 4_096))
      if let suffix = try handle.read(upToCount: 4_096) {
        hasher.update(data: suffix)
      }
    }
  }
}
