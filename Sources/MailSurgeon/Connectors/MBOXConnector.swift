import Foundation

struct MBOXConnector: MailSourceConnector {
  let descriptor: MailSourceDescriptor
  private let parser = MailMessageParser()

  func validateAccess() async throws {
    guard let url = descriptor.location else {
      throw ConnectorError.accessDenied("Nebyl vybrán soubor MBOX.")
    }

    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped { url.stopAccessingSecurityScopedResource() }
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ConnectorError.missingFile(url.path)
    }

    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw ConnectorError.unreadableFile(url.lastPathComponent)
    }

    _ = try mboxFiles(in: url)
  }

  func folders() async throws -> [String] {
    guard let url = descriptor.location else { return ["MBOX"] }
    let files = try mboxFiles(in: url)
    return files.map { folderName(for: $0, root: url) }
  }

  func scanMessages() -> AsyncThrowingStream<MailMessageRecord, Error> {
    AsyncThrowingStream { continuation in
      Task.detached {
        do {
          guard let url = descriptor.location else {
            throw ConnectorError.accessDenied("Nebyl vybrán soubor MBOX.")
          }

          let scoped = url.startAccessingSecurityScopedResource()
          defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
          }

          let files = try mboxFiles(in: url)
          var emittedMessages = 0
          for fileURL in files {
            try Task.checkCancellation()
            emittedMessages += try scanFile(
              fileURL,
              root: url,
              startingAt: emittedMessages,
              continuation: continuation
            )
          }

          guard emittedMessages > 0 else {
            throw ConnectorError.emptyArchive(url.lastPathComponent)
          }

          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  private func mboxFiles(in url: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw ConnectorError.missingFile(url.path)
    }

    if !isDirectory.boolValue {
      guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw ConnectorError.unreadableFile(url.lastPathComponent)
      }
      return [url]
    }

    let bundleFile = url.appendingPathComponent("mbox")
    if FileManager.default.fileExists(atPath: bundleFile.path),
      FileManager.default.isReadableFile(atPath: bundleFile.path)
    {
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
      guard values.isRegularFile == true,
        values.isReadable == true
      else { continue }

      if fileURL.lastPathComponent == "mbox" || fileURL.pathExtension.lowercased() == "mbox" {
        files.append(fileURL)
      }
    }

    guard !files.isEmpty else {
      throw ConnectorError.malformedArchive("Ve vybrané složce nebyl nalezen čitelný MBOX soubor.")
    }

    return files.sorted { $0.path < $1.path }
  }

  private func scanFile(
    _ fileURL: URL,
    root: URL,
    startingAt startingIndex: Int,
    continuation: AsyncThrowingStream<MailMessageRecord, Error>.Continuation
  ) throws -> Int {
    guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
      throw ConnectorError.unreadableFile(fileURL.lastPathComponent)
    }

    let handle = try FileHandle(forReadingFrom: fileURL)
    defer {
      try? handle.close()
    }

    var pending = Data()
    var currentMessage = Data()
    var currentMessageOffset: UInt64 = 0
    var consumedOffset: UInt64 = 0
    var emittedMessages = 0
    var sawDelimiter = false
    var sawNonEmptyBeforeDelimiter = false
    let newline = Data([0x0A])

    func consume(_ line: Data, at lineOffset: UInt64) throws {
      try Task.checkCancellation()

      if isMBOXDelimiter(line) {
        sawDelimiter = true
        if !currentMessage.isEmpty {
          emittedMessages += 1
          continuation.yield(
            record(
              from: currentMessage,
              fileURL: fileURL,
              root: root,
              byteOffset: currentMessageOffset
            ))
          currentMessage.removeAll(keepingCapacity: true)
        }
        currentMessageOffset = lineOffset + UInt64(line.count)
        return
      }

      if !sawDelimiter && !line.trimmingASCIIWhitespace().isEmpty {
        sawNonEmptyBeforeDelimiter = true
      }

      if sawDelimiter {
        currentMessage.append(line)
      }
    }

    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
      pending.append(chunk)
      while let range = pending.firstRange(of: newline) {
        let line = pending[..<range.upperBound]
        let lineData = Data(line)
        try consume(lineData, at: consumedOffset)
        consumedOffset += UInt64(lineData.count)
        pending.removeSubrange(..<range.upperBound)
      }
    }

    if !pending.isEmpty {
      try consume(pending, at: consumedOffset)
      consumedOffset += UInt64(pending.count)
    }

    if !currentMessage.isEmpty {
      emittedMessages += 1
      continuation.yield(
        record(
          from: currentMessage,
          fileURL: fileURL,
          root: root,
          byteOffset: currentMessageOffset
        ))
    }

    if !sawDelimiter && sawNonEmptyBeforeDelimiter {
      throw ConnectorError.malformedArchive(
        "\(fileURL.lastPathComponent) nezačíná MBOX oddělovačem „From “.")
    }

    return emittedMessages
  }

  private func isMBOXDelimiter(_ line: Data) -> Bool {
    let prefix = Data("From ".utf8)
    return line.starts(with: prefix)
  }

  private func record(from rawData: Data, fileURL: URL, root: URL, byteOffset: UInt64)
    -> MailMessageRecord
  {
    parser.record(
      from: rawData,
      fileURL: fileURL,
      root: root,
      folder: folderName(for: fileURL, root: root),
      byteOffset: byteOffset
    )
  }

  private func folderName(for fileURL: URL, root: URL) -> String {
    if fileURL.lastPathComponent == "mbox" {
      return fileURL.deletingLastPathComponent().deletingPathExtension().lastPathComponent
    }
    if fileURL == root {
      return fileURL.deletingPathExtension().lastPathComponent
    }
    return fileURL.deletingPathExtension().lastPathComponent
  }

}

extension Data {
  fileprivate func trimmingASCIIWhitespace() -> Data {
    let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
    var start = startIndex
    var end = endIndex

    while start < end, whitespace.contains(self[start]) {
      start = index(after: start)
    }

    while end > start {
      let previous = index(before: end)
      guard whitespace.contains(self[previous]) else { break }
      end = previous
    }

    return self[start..<end]
  }
}
