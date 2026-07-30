import CryptoKit
import Foundation

struct RecoveryExportService: Sendable {
  typealias ProgressHandler = @MainActor @Sendable (RecoveryScanProgress) -> Void

  private let policy: RecoveryPolicy

  init(policy: RecoveryPolicy = RecoveryPolicy()) {
    self.policy = policy
  }

  func export(
    source: MailSourceDescriptor,
    report: RecoveryReport,
    mode: RecoveryExportMode,
    destination: URL,
    selectedSuggestionIDs: Set<String> = [],
    progress: ProgressHandler? = nil
  ) async throws -> RecoveryExportResult {
    guard source.kind == .mbox else { throw RecoveryError.unsupportedSourceKind }
    guard let sourceURL = source.location else { throw RecoveryError.missingSourceLocation }

    return try await Task.detached {
      let scoped = sourceURL.startAccessingSecurityScopedResource()
      defer {
        if scoped { sourceURL.stopAccessingSecurityScopedResource() }
      }

      try validateDestination(destination, sourceURL: sourceURL)
      let temporaryURL = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
      let quarantineURL =
        mode == .recoverableOnly
        ? destination.deletingPathExtension().appendingPathExtension("quarantine.mbox")
        : nil
      let temporaryQuarantineURL = quarantineURL.map {
        $0.deletingLastPathComponent()
          .appendingPathComponent(".\($0.lastPathComponent).tmp-\(UUID().uuidString)")
      }

      let sourceData = try Data(contentsOf: sourceURL)
      let originalSourceData = sourceData
      let regions = splitMBOXRegions(sourceData: sourceData, sourceURL: sourceURL)
      if regions.isEmpty { throw RecoveryError.emptySource }

      let duplicateIDs = duplicateRegionIDs(regions)
      let unrecoverable = Set(
        report.issues.filter { $0.severity == .critical }.compactMap(\.messageSummaryID)
      )
      let issuesByID = Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, $0) })
      let selectedGeneratedMessageIDRepairs = Set(
        report.suggestions.filter {
          selectedSuggestionIDs.contains($0.id)
            && $0.action == .generateDeterministicMessageID
        }
        .compactMap { issuesByID[$0.issueID]?.messageSummaryID }
      )
      var exported = 0
      var quarantined = 0
      var excludedDuplicates = 0

      FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
      let output = try FileHandle(forWritingTo: temporaryURL)
      let quarantine: FileHandle? = try temporaryQuarantineURL.map { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
      }
      var completed = false
      defer {
        try? output.close()
        try? quarantine?.close()
        if !completed {
          try? FileManager.default.removeItem(at: temporaryURL)
          if let temporaryQuarantineURL {
            try? FileManager.default.removeItem(at: temporaryQuarantineURL)
          }
        }
      }

      for index in regions.indices {
        try Task.checkCancellation()
        var region = regions[index]
        let isDuplicate = duplicateIDs.contains(region.id)
        let isUnrecoverable = unrecoverable.contains(region.id)

        if mode == .deduplicated, isDuplicate {
          excludedDuplicates += 1
          continue
        }
        if mode == .recoverableOnly, isUnrecoverable {
          if let quarantine {
            quarantine.write(
              escapedMBOXMessage(region: region, selectedSuggestionIDs: selectedSuggestionIDs))
            quarantined += 1
          }
          continue
        }

        if selectedGeneratedMessageIDRepairs.contains(region.id) {
          region.message = addGeneratedMessageIDIfMissing(region.message)
        }
        output.write(
          escapedMBOXMessage(region: region, selectedSuggestionIDs: selectedSuggestionIDs))
        exported += 1

        if index % 100 == 0 {
          let progressValue = RecoveryScanProgress(
            status: .running,
            messagesScanned: exported + quarantined,
            bytesScanned: Int64(region.sourceEnd),
            totalBytes: Int64(sourceData.count),
            issuesFound: report.totalIssues,
            startedAt: report.startedAt,
            completedAt: nil,
            statusText: "Exporting recovery MBOX..."
          )
          Task { await progress?(progressValue) }
        }
      }

      try output.close()
      try quarantine?.close()
      try replaceAtomically(temporaryURL, destination: destination)
      if let temporaryQuarantineURL, let quarantineURL {
        try replaceAtomically(temporaryQuarantineURL, destination: quarantineURL)
      }
      let reportURL = destination.deletingPathExtension().appendingPathExtension("recovery.json")
      try report.jsonData().write(to: reportURL, options: .atomic)
      let outputSHA = sha256Hex(try Data(contentsOf: destination))
      guard try Data(contentsOf: sourceURL) == originalSourceData else {
        throw RecoveryError.unreadableSource(sourceURL)
      }
      completed = true
      return RecoveryExportResult(
        outputURL: destination,
        quarantineURL: quarantineURL,
        reportURL: reportURL,
        outputSHA256: outputSHA,
        exportedMessageCount: exported,
        quarantinedMessageCount: quarantined,
        excludedDuplicateCount: excludedDuplicates
      )
    }.value
  }
}

private struct ExportRegion {
  var id: String
  var delimiter: Data
  var message: Data
  var sourceStart: Int
  var sourceEnd: Int
  var rawHash: String
}

private func validateDestination(_ destination: URL, sourceURL: URL) throws {
  let standardizedDestination = destination.standardizedFileURL
  let standardizedSource = sourceURL.standardizedFileURL
  if standardizedDestination.path == standardizedSource.path {
    throw RecoveryError.sourceAndDestinationMatch
  }
  let tempPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
  let destinationPath = standardizedDestination.path
  if destinationPath == tempPath || destinationPath.hasPrefix(tempPath + "/") {
    throw RecoveryError.unsafeDestination(destination)
  }
  try FileManager.default.createDirectory(
    at: standardizedDestination.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
}

private func splitMBOXRegions(sourceData: Data, sourceURL: URL) -> [ExportRegion] {
  var regions: [ExportRegion] = []
  var lines: [(range: Range<Data.Index>, line: Data)] = []
  var cursor = sourceData.startIndex
  while cursor < sourceData.endIndex {
    let end =
      sourceData[cursor...].firstIndex(of: 0x0A).map { sourceData.index(after: $0) }
      ?? sourceData.endIndex
    lines.append((cursor..<end, Data(sourceData[cursor..<end])))
    cursor = end
  }

  var currentDelimiter: Data?
  var currentStart: Int?
  var currentMessageStart: Int?
  for line in lines {
    if line.line.starts(with: Data("From ".utf8)), isValidFromDelimiter(line.line) {
      if let delimiter = currentDelimiter,
        let start = currentStart,
        let messageStart = currentMessageStart
      {
        let message = Data(sourceData[messageStart..<line.range.lowerBound])
        let offset = UInt64(messageStart)
        let id = "\(sourceURL.path)#\(offset):\(message.count)"
        regions.append(
          ExportRegion(
            id: id,
            delimiter: delimiter,
            message: message,
            sourceStart: start,
            sourceEnd: line.range.lowerBound,
            rawHash: sha256Hex(message)
          ))
      }
      currentDelimiter = line.line
      currentStart = line.range.lowerBound
      currentMessageStart = line.range.upperBound
    }
  }
  if let delimiter = currentDelimiter,
    let start = currentStart,
    let messageStart = currentMessageStart
  {
    let message = Data(sourceData[messageStart..<sourceData.endIndex])
    let offset = UInt64(messageStart)
    let id = "\(sourceURL.path)#\(offset):\(message.count)"
    regions.append(
      ExportRegion(
        id: id,
        delimiter: delimiter,
        message: message,
        sourceStart: start,
        sourceEnd: sourceData.endIndex,
        rawHash: sha256Hex(message)
      ))
  }
  return regions
}

private func duplicateRegionIDs(_ regions: [ExportRegion]) -> Set<String> {
  let groups = Dictionary(grouping: regions, by: \.rawHash)
  var duplicateIDs: Set<String> = []
  for group in groups.values where group.count > 1 {
    let sorted = group.sorted { $0.id < $1.id }
    duplicateIDs.formUnion(sorted.dropFirst().map(\.id))
  }
  return duplicateIDs
}

private func escapedMBOXMessage(region: ExportRegion, selectedSuggestionIDs: Set<String>) -> Data {
  var output = Data()
  output.append(region.delimiter)
  if region.delimiter.last != 0x0A {
    output.append(0x0A)
  }
  var cursor = region.message.startIndex
  while cursor < region.message.endIndex {
    let end =
      region.message[cursor...].firstIndex(of: 0x0A).map {
        region.message.index(after: $0)
      } ?? region.message.endIndex
    let line = Data(region.message[cursor..<end])
    if line.starts(with: Data("From ".utf8)) {
      output.append(0x3E)
    }
    output.append(line)
    cursor = end
  }
  if output.last != 0x0A {
    output.append(0x0A)
  }
  return output
}

private func addGeneratedMessageIDIfMissing(_ data: Data) -> Data {
  guard let separator = data.firstRange(of: Data([0x0A, 0x0A])) else { return data }
  let headerData = Data(data[..<separator.lowerBound])
  let headerText = String(data: headerData, encoding: .isoLatin1) ?? ""
  guard !headerText.localizedCaseInsensitiveContains("message-id:") else { return data }
  let generated = "Message-ID: <mail-surgeon-\(sha256Hex(data).prefix(32))@recovery.local>\n"
  var output = Data(generated.utf8)
  output.append(data)
  return output
}

private func replaceAtomically(_ temporaryURL: URL, destination: URL) throws {
  if FileManager.default.fileExists(atPath: destination.path) {
    try FileManager.default.removeItem(at: destination)
  }
  try FileManager.default.moveItem(at: temporaryURL, to: destination)
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func isValidFromDelimiter(_ line: Data) -> Bool {
  guard let text = String(data: line, encoding: .isoLatin1) else { return false }
  let pattern = #"^From \S+ .*\d{4}\s*$"#
  return text.range(of: pattern, options: .regularExpression) != nil
}
