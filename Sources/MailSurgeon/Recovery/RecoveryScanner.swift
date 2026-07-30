import CryptoKit
import Foundation

struct RecoveryScanner: Sendable {
  typealias ProgressHandler = @MainActor @Sendable (RecoveryScanProgress) -> Void

  private let parser = MailMessageParser()
  private let policy: RecoveryPolicy

  init(policy: RecoveryPolicy = RecoveryPolicy()) {
    self.policy = policy
  }

  func scan(
    source: MailSourceDescriptor,
    progress: ProgressHandler? = nil
  ) async throws -> RecoveryReport {
    guard source.kind == .mbox else { throw RecoveryError.unsupportedSourceKind }
    guard let rootURL = source.location else { throw RecoveryError.missingSourceLocation }

    return try await Task.detached {
      let scoped = rootURL.startAccessingSecurityScopedResource()
      defer {
        if scoped { rootURL.stopAccessingSecurityScopedResource() }
      }

      let startedAt = Date()
      let fingerprint = try MailIndexingService.fingerprint(for: source)
      let files = try mboxFiles(in: rootURL)
      var totalBytes: Int64 = 0
      for url in files {
        totalBytes += try fileSize(url)
      }
      var context = ScanContext(sourceID: source.id, sourceName: source.name, policy: policy)

      await progress?(
        RecoveryScanProgress(
          status: .running,
          messagesScanned: 0,
          bytesScanned: 0,
          totalBytes: totalBytes,
          issuesFound: 0,
          startedAt: startedAt,
          completedAt: nil,
          statusText: "Starting recovery scan..."
        ))

      for fileURL in files {
        try Task.checkCancellation()
        try scanFile(
          fileURL,
          root: rootURL,
          context: &context,
          totalBytes: totalBytes,
          startedAt: startedAt,
          progress: progress
        )
      }

      if context.messageCount == 0 {
        throw RecoveryError.emptySource
      }

      context.finishDuplicateAnalysis()
      let completedAt = Date()
      let report = RecoveryReport(
        id: UUID(),
        sourceID: source.id,
        sourceName: source.name,
        sourceFingerprint: fingerprint,
        scannerVersion: policy.scannerVersion,
        startedAt: startedAt,
        completedAt: completedAt,
        totalMessagesScanned: context.messageCount,
        totalBytesScanned: context.bytesScanned,
        issues: context.issues,
        suggestions: context.suggestions,
        estimatedOutputMessageCount: context.messageCount - context.exactDuplicateCopies,
        estimatedRemovedDuplicateCount: context.exactDuplicateCopies,
        estimatedQuarantinedMessageCount: context.unrecoverableMessageIDs.count,
        estimatedOutputByteSize: max(0, context.bytesScanned - context.exactDuplicateBytes),
        privacyIncludesSubjectsSendersAndMessageIDs: policy.includePrivacySensitiveReportFields
      )

      await progress?(
        RecoveryScanProgress(
          status: .completed,
          messagesScanned: context.messageCount,
          bytesScanned: context.bytesScanned,
          totalBytes: totalBytes,
          issuesFound: context.issues.count,
          startedAt: startedAt,
          completedAt: completedAt,
          statusText: "Recovery dry run completed. Source mailbox was not modified."
        ))
      return report
    }.value
  }
}

private struct MessageRegion {
  var raw: Data
  var fileURL: URL
  var rootURL: URL
  var offset: UInt64
  var delimiterOffset: UInt64
  var delimiter: Data
  var finalHadNewline: Bool
}

private struct HeaderField {
  var name: String
  var value: String
  var lineOffset: UInt64
  var rawLine: String
}

private struct ParsedHeaderBlock {
  var fields: [HeaderField]
  var body: Data
  var bodyOffset: UInt64
  var hasTerminator: Bool
  var malformedLines: [(line: String, offset: UInt64)]
  var orphanFoldedLines: [(line: String, offset: UInt64)]
  var hasBinaryBytes: Bool
}

private struct MessageFacts {
  var record: MailMessageRecord
  var bodyHash: String
  var messageID: String?
}

private struct ScanContext {
  let sourceID: UUID
  let sourceName: String
  let policy: RecoveryPolicy
  var issues: [RecoveryIssue] = []
  var suggestions: [RecoverySuggestion] = []
  var messageCount = 0
  var bytesScanned: Int64 = 0
  var facts: [MessageFacts] = []
  var seenSourceRanges: [(start: UInt64, end: UInt64)] = []
  var unrecoverableMessageIDs: Set<String> = []
  var exactDuplicateCopies = 0
  var exactDuplicateBytes: Int64 = 0

  mutating func appendIssue(
    sourceID: UUID,
    message: MailMessageRecord?,
    kind: RecoveryIssueKind,
    severity: RecoverySeverity,
    confidence: RecoveryConfidence,
    title: String,
    explanation: String,
    offset: UInt64?,
    length: Int64?,
    repairable: Bool,
    action: RecoverySuggestionAction,
    evidence: [String: String] = [:],
    suggestion: RecoverySuggestion? = nil
  ) {
    var mergedEvidence = evidence
    if let message {
      mergedEvidence["messageDate"] =
        message.sentDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
      if policy.includePrivacySensitiveReportFields {
        mergedEvidence["subject"] = message.subject
        mergedEvidence["sender"] = message.sender
        mergedEvidence["messageID"] = message.messageID ?? ""
      } else {
        mergedEvidence["subjectHash"] = sha256Hex(Data(message.subject.utf8))
        mergedEvidence["senderHash"] = sha256Hex(Data(message.sender.utf8))
        if let messageID = message.messageID {
          mergedEvidence["messageIDHash"] = sha256Hex(Data(messageID.utf8))
        }
      }
    }
    let seed = [
      sourceID.uuidString,
      message?.sourceIdentifier ?? "source",
      kind.rawValue,
      String(offset ?? 0),
      String(length ?? 0),
      mergedEvidence.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
        separator: "|"),
    ].joined(separator: "|")
    let id = "rec-\(sha256Hex(Data(seed.utf8)).prefix(24))"
    let issue = RecoveryIssue(
      id: id,
      sourceID: sourceID,
      messageSummaryID: message?.sourceIdentifier,
      kind: kind,
      severity: severity,
      confidence: confidence,
      title: title,
      technicalExplanation: explanation,
      byteOffset: offset,
      byteLength: length,
      isSafelyRepairable: repairable,
      suggestedAction: action,
      evidence: mergedEvidence
    )
    issues.append(issue)

    if var suggestion {
      suggestion = RecoverySuggestion(
        id: suggestion.id,
        issueID: id,
        action: suggestion.action,
        originalCondition: suggestion.originalCondition,
        proposedChange: suggestion.proposedChange,
        confidence: suggestion.confidence,
        changesRawBytes: suggestion.changesRawBytes,
        metadataOnly: suggestion.metadataOnly,
        requiresUserConfirmation: suggestion.requiresUserConfirmation
      )
      suggestions.append(suggestion)
    }

    if severity == .critical {
      if let message {
        unrecoverableMessageIDs.insert(message.sourceIdentifier)
      }
    }
  }

  mutating func finishDuplicateAnalysis() {
    for group in Dictionary(grouping: facts, by: \.record.rawSHA256).values where group.count > 1 {
      let canonical = group.sorted { $0.record.sourceIdentifier < $1.record.sourceIdentifier }[0]
      for duplicate in group
      where duplicate.record.sourceIdentifier != canonical.record.sourceIdentifier {
        exactDuplicateCopies += 1
        exactDuplicateBytes += duplicate.record.byteSize
        appendIssue(
          sourceID: sourceID,
          message: duplicate.record,
          kind: .exactDuplicateMessageHash,
          severity: .info,
          confidence: .high,
          title: "Exact duplicate message hash",
          explanation:
            "This message has the same raw SHA-256 as another message. This is a confirmed duplicate copy, not source corruption.",
          offset: duplicate.record.location?.byteOffset,
          length: duplicate.record.location?.byteLength,
          repairable: true,
          action: .removeDuplicateTransportCopyOnExport,
          evidence: [
            "rawSHA256": duplicate.record.rawSHA256,
            "canonicalMessage": canonical.record.sourceIdentifier,
          ],
          suggestion: suggestion(
            action: .removeDuplicateTransportCopyOnExport,
            original: "Duplicate raw message hash \(duplicate.record.rawSHA256).",
            change: "Exclude this transport copy only when using deduplicated export.",
            confidence: .high,
            raw: false,
            metadataOnly: true
          )
        )
      }
    }

    for group in Dictionary(
      grouping: facts.compactMap { fact -> MessageFacts? in
        guard fact.messageID != nil else { return nil }
        return fact
      }, by: { $0.messageID!.lowercased() }
    ).values where group.count > 1 {
      let hashes = Set(group.map(\.record.rawSHA256))
      for fact in group {
        appendIssue(
          sourceID: sourceID,
          message: fact.record,
          kind: .duplicateMessageID,
          severity: hashes.count == 1 ? .info : .warning,
          confidence: .high,
          title: "Duplicate Message-ID",
          explanation:
            hashes.count == 1
            ? "Multiple messages share the same Message-ID and raw hash."
            : "Multiple messages share the same Message-ID. Their raw hashes differ, so a separate suspicious-content issue is also recorded.",
          offset: fact.record.location?.byteOffset,
          length: fact.record.location?.byteLength,
          repairable: hashes.count == 1,
          action: hashes.count == 1 ? .preserveCanonicalDuplicate : .inspectManually,
          evidence: [
            "messageIDHash": sha256Hex(Data((fact.messageID ?? "").utf8)),
            "hashCount": "\(hashes.count)",
          ]
        )
        if hashes.count > 1 {
          appendIssue(
            sourceID: sourceID,
            message: fact.record,
            kind: .sameMessageIDDifferentHash,
            severity: .warning,
            confidence: .high,
            title: "Same Message-ID with different content",
            explanation:
              "Multiple messages share the same Message-ID but have different raw hashes. This is suspicious and should be reviewed before export.",
            offset: fact.record.location?.byteOffset,
            length: fact.record.location?.byteLength,
            repairable: false,
            action: .inspectManually,
            evidence: [
              "messageIDHash": sha256Hex(Data((fact.messageID ?? "").utf8)),
              "hashCount": "\(hashes.count)",
            ]
          )
        }
      }
    }

    for group in Dictionary(grouping: facts, by: \.bodyHash).values where group.count > 1 {
      let transportHashes = Set(group.map(\.record.rawSHA256))
      guard transportHashes.count > 1 else { continue }
      for fact in group {
        appendIssue(
          sourceID: sourceID,
          message: fact.record,
          kind: .sameBodyDifferentTransportHeaders,
          severity: .info,
          confidence: .medium,
          title: "Same body with different transport headers",
          explanation:
            "The decoded body region matches another message but the transport headers or raw bytes differ. This is a compatibility warning, not confirmed corruption.",
          offset: fact.record.location?.byteOffset,
          length: fact.record.location?.byteLength,
          repairable: false,
          action: .inspectManually,
          evidence: ["bodyHash": fact.bodyHash]
        )
      }
    }
  }
}

private func mboxFiles(in url: URL) throws -> [URL] {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
    throw RecoveryError.unreadableSource(url)
  }

  if !isDirectory.boolValue {
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw RecoveryError.unreadableSource(url)
    }
    return [url]
  }

  let bundleFile = url.appendingPathComponent("mbox")
  if FileManager.default.isReadableFile(atPath: bundleFile.path) {
    return [bundleFile]
  }

  guard
    let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey],
      options: [.skipsHiddenFiles]
    )
  else {
    throw RecoveryError.unreadableSource(url)
  }

  var files: [URL] = []
  for case let fileURL as URL in enumerator {
    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
    if values.isRegularFile == true,
      values.isReadable == true,
      fileURL.lastPathComponent == "mbox" || fileURL.pathExtension.lowercased() == "mbox"
    {
      files.append(fileURL)
    }
  }
  return files.sorted { $0.path < $1.path }
}

private func scanFile(
  _ fileURL: URL,
  root: URL,
  context: inout ScanContext,
  totalBytes: Int64,
  startedAt: Date,
  progress: RecoveryScanner.ProgressHandler?
) throws {
  let handle = try FileHandle(forReadingFrom: fileURL)
  defer { try? handle.close() }

  var pending = Data()
  var current = Data()
  var currentOffset: UInt64 = 0
  var currentDelimiterOffset: UInt64 = 0
  var currentDelimiter = Data()
  var consumedOffset: UInt64 = 0
  var sawDelimiter = false
  var lastProgressDate = Date.distantPast
  let newline = Data([0x0A])

  func emit(finalHadNewline: Bool) throws {
    try Task.checkCancellation()
    guard sawDelimiter else { return }
    let region = MessageRegion(
      raw: current,
      fileURL: fileURL,
      rootURL: root,
      offset: currentOffset,
      delimiterOffset: currentDelimiterOffset,
      delimiter: currentDelimiter,
      finalHadNewline: finalHadNewline
    )
    analyze(region: region, context: &context)
    current.removeAll(keepingCapacity: true)
    let now = Date()
    if now.timeIntervalSince(lastProgressDate) >= 0.05 {
      lastProgressDate = now
      let progressValue = RecoveryScanProgress(
        status: .running,
        messagesScanned: context.messageCount,
        bytesScanned: context.bytesScanned,
        totalBytes: totalBytes,
        issuesFound: context.issues.count,
        startedAt: startedAt,
        completedAt: nil,
        statusText: "Scanning \(fileURL.lastPathComponent)"
      )
      Task { await progress?(progressValue) }
    }
  }

  func consume(_ line: Data, at lineOffset: UInt64, hasTrailingNewline: Bool) throws {
    try Task.checkCancellation()
    if line.starts(with: Data("From ".utf8)), isValidFromDelimiter(line) {
      if sawDelimiter {
        try emit(finalHadNewline: true)
      }
      sawDelimiter = true
      currentDelimiterOffset = lineOffset
      currentDelimiter = line
      currentOffset = lineOffset + UInt64(line.count)
      return
    }

    if line.starts(with: Data("From ".utf8)), !sawDelimiter {
      context.appendIssue(
        sourceID: context.sourceID,
        message: nil,
        kind: .malformedFromSeparator,
        severity: .error,
        confidence: .high,
        title: "Malformed MBOX From_ separator",
        explanation: "A From_ line appears before any valid MBOX separator but is malformed.",
        offset: lineOffset,
        length: Int64(line.count),
        repairable: false,
        action: .inspectManually,
        evidence: ["delimiterSHA256": sha256Hex(line)]
      )
      return
    }

    if !sawDelimiter && !line.trimmingASCIIWhitespace().isEmpty {
      context.appendIssue(
        sourceID: context.sourceID,
        message: nil,
        kind: .messageBeforeValidFromDelimiter,
        severity: .error,
        confidence: .high,
        title: "Data before first valid MBOX delimiter",
        explanation:
          "Non-empty bytes appear before the first From_ separator. They were not treated as a normal message.",
        offset: lineOffset,
        length: Int64(line.count),
        repairable: false,
        action: .quarantineMessage,
        evidence: ["lineSHA256": sha256Hex(line)]
      )
      return
    }

    if sawDelimiter {
      let normalizedLine = line.trimmingLineEnding()
      if normalizedLine.starts(with: Data("From ".utf8)) {
        context.appendIssue(
          sourceID: context.sourceID,
          message: nil,
          kind: .unescapedBodyFromLine,
          severity: .warning,
          confidence: .medium,
          title: "Body line resembles an MBOX delimiter",
          explanation:
            "A body line begins with From_. Export will escape it using standard MBOX escaping.",
          offset: lineOffset,
          length: Int64(line.count),
          repairable: true,
          action: .normalizeLineEndings
        )
      }
      current.append(line)
      if !hasTrailingNewline {
        context.appendIssue(
          sourceID: context.sourceID,
          message: nil,
          kind: .truncatedFinalMessage,
          severity: .warning,
          confidence: .medium,
          title: "Final message does not end with a newline",
          explanation:
            "The last message ended without a trailing newline. A recovery export can reconstruct the final newline.",
          offset: lineOffset,
          length: Int64(line.count),
          repairable: true,
          action: .reconstructFinalNewline,
          suggestion: suggestion(
            action: .reconstructFinalNewline,
            original: "Final message has no trailing newline.",
            change: "Append one LF byte during export if selected.",
            confidence: .medium,
            raw: true,
            metadataOnly: false
          )
        )
      }
    }
  }

  while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
    pending.append(chunk)
    while let range = pending.firstRange(of: newline) {
      let line = Data(pending[..<range.upperBound])
      try consume(line, at: consumedOffset, hasTrailingNewline: true)
      consumedOffset += UInt64(line.count)
      pending.removeSubrange(..<range.upperBound)
    }
  }

  if !pending.isEmpty {
    try consume(pending, at: consumedOffset, hasTrailingNewline: false)
    consumedOffset += UInt64(pending.count)
  }

  if sawDelimiter {
    try emit(finalHadNewline: pending.isEmpty)
  }
}

private func analyze(region: MessageRegion, context: inout ScanContext) {
  let folder =
    region.fileURL.lastPathComponent == "mbox"
    ? region.fileURL.deletingLastPathComponent().deletingPathExtension().lastPathComponent
    : region.fileURL.deletingPathExtension().lastPathComponent
  let record = MailMessageParser().record(
    from: region.raw,
    fileURL: region.fileURL,
    root: region.rootURL,
    folder: folder,
    byteOffset: region.offset
  )
  context.messageCount += 1
  context.bytesScanned += record.byteSize

  let end = region.offset + UInt64(max(0, record.byteSize))
  if record.byteSize <= 0 {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .zeroLengthMessage,
      severity: .critical,
      confidence: .high,
      title: "Zero-length message",
      explanation: "The message region between MBOX delimiters is empty.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .quarantineMessage
    )
  }
  if context.seenSourceRanges.contains(where: { range in
    region.offset < range.end && end > range.start
  }) {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .invalidSourceOffsets,
      severity: .critical,
      confidence: .high,
      title: "Overlapping source offsets",
      explanation: "This message overlaps another indexed source byte range.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .quarantineMessage
    )
  }
  context.seenSourceRanges.append((region.offset, end))

  let parsedHeaders = parseHeaderBlock(region.raw, baseOffset: region.offset)
  analyzeHeaders(parsedHeaders, region: region, record: record, context: &context)
  analyzeMIME(parsedHeaders, region: region, record: record, context: &context)

  context.facts.append(
    MessageFacts(
      record: record,
      bodyHash: sha256Hex(parsedHeaders.body),
      messageID: record.messageID?.trimmingCharacters(in: .whitespacesAndNewlines)
    ))
}

private func analyzeHeaders(
  _ parsed: ParsedHeaderBlock,
  region: MessageRegion,
  record: MailMessageRecord,
  context: inout ScanContext
) {
  if !parsed.hasTerminator {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .missingHeaderTerminator,
      severity: .error,
      confidence: .high,
      title: "Headers have no terminating blank line",
      explanation:
        "The message has no blank line separating headers from the body. Body parsing is therefore uncertain.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually
    )
  }
  if parsed.hasBinaryBytes {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .binaryBytesInHeaders,
      severity: .error,
      confidence: .high,
      title: "Unexpected binary bytes in headers",
      explanation: "Header bytes contain control bytes outside tab and line endings.",
      offset: region.offset,
      length: Int64(max(0, Int(parsed.bodyOffset - region.offset))),
      repairable: false,
      action: .inspectManually
    )
  }
  for line in parsed.malformedLines {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .malformedHeader,
      severity: .warning,
      confidence: .high,
      title: "Malformed header line",
      explanation: "A non-empty header line does not contain a colon.",
      offset: line.offset,
      length: Int64(line.line.utf8.count),
      repairable: false,
      action: .inspectManually,
      evidence: ["lineSHA256": sha256Hex(Data(line.line.utf8))]
    )
  }
  for line in parsed.orphanFoldedLines {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .foldedHeaderWithoutParent,
      severity: .warning,
      confidence: .high,
      title: "Folded header without parent",
      explanation: "A folded header continuation appears before any header field.",
      offset: line.offset,
      length: Int64(line.line.utf8.count),
      repairable: false,
      action: .inspectManually
    )
  }

  if record.messageID == nil
    || record.messageID?.trimmingCharacters(in: .whitespaces).isEmpty == true
  {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .missingMessageID,
      severity: .warning,
      confidence: .high,
      title: "Missing Message-ID",
      explanation:
        "The message has no Message-ID header. A deterministic recovery-only Message-ID can be generated for export metadata.",
      offset: region.offset,
      length: record.byteSize,
      repairable: true,
      action: .generateDeterministicMessageID,
      evidence: ["rawSHA256": record.rawSHA256],
      suggestion: suggestion(
        action: .generateDeterministicMessageID,
        original: "Message-ID header is missing.",
        change:
          "Generate \(context.policy.deterministicMessageID(for: record)) during selected export.",
        confidence: .high,
        raw: true,
        metadataOnly: false
      )
    )
  } else if let messageID = record.messageID, !isValidMessageID(messageID) {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .malformedMessageID,
      severity: .warning,
      confidence: .high,
      title: "Malformed Message-ID",
      explanation: "The Message-ID does not match the conservative <local@domain> form.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually,
      evidence: ["messageIDHash": sha256Hex(Data(messageID.utf8))]
    )
  }

  if !hasHeader("Date", fields: parsed.fields) {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .missingDateHeader,
      severity: .warning,
      confidence: .high,
      title: "Missing Date header",
      explanation: "The message has no Date header.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually
    )
  } else if record.sentDate == nil {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .invalidDateHeader,
      severity: .warning,
      confidence: .high,
      title: "Invalid Date header",
      explanation: "The Date header could not be parsed using supported RFC-style formats.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually
    )
  }

  if !hasHeader("From", fields: parsed.fields) {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .missingFromHeader,
      severity: .warning,
      confidence: .high,
      title: "Missing From header",
      explanation: "The message has no From header.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually
    )
  }
  if !["To", "Cc", "Bcc"].contains(where: { hasHeader($0, fields: parsed.fields) }) {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .missingRecipientHeaders,
      severity: .info,
      confidence: .high,
      title: "Missing recipient headers",
      explanation:
        "The message has no To, Cc, or Bcc header. Some legitimate messages omit these fields.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually
    )
  }

  if !hasHeader("Content-Type", fields: parsed.fields) {
    let inferable = context.policy.safeDefaultContentType(for: parsed.body)
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .missingContentType,
      severity: .info,
      confidence: inferable == nil ? .medium : .high,
      title: "Missing Content-Type",
      explanation:
        "The message has no Content-Type header. Plain text may be safely inferable for export.",
      offset: region.offset,
      length: record.byteSize,
      repairable: inferable != nil,
      action: inferable == nil ? .inspectManually : .addDefaultContentType,
      evidence: ["inferredContentType": inferable ?? ""],
      suggestion: inferable.map {
        suggestion(
          action: .addDefaultContentType,
          original: "Content-Type header is missing.",
          change: "Add Content-Type: \($0) during selected export.",
          confidence: .high,
          raw: true,
          metadataOnly: false
        )
      }
    )
  }
}

private func analyzeMIME(
  _ parsed: ParsedHeaderBlock,
  region: MessageRegion,
  record: MailMessageRecord,
  context: inout ScanContext
) {
  let contentType = headerValue("Content-Type", fields: parsed.fields)
  let transferEncoding = headerValue("Content-Transfer-Encoding", fields: parsed.fields)?
    .lowercased()
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let bodyText = String(data: parsed.body, encoding: .isoLatin1) ?? ""
  let mimeMessage = MIMEParser().parse(region.raw)

  if let contentType, contentType.lowercased().contains("multipart/"),
    !contentType.lowercased().contains("boundary=")
  {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .missingMultipartBoundary,
      severity: .error,
      confidence: .high,
      title: "Multipart message is missing a boundary",
      explanation: "Content-Type declares multipart content but has no boundary parameter.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually
    )
  }

  for warning in mimeMessage.warnings {
    if warning.contains("missing a closing boundary") {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .unterminatedMultipartBoundary,
        severity: .warning,
        confidence: .high,
        title: "Unterminated multipart boundary",
        explanation: warning,
        offset: region.offset,
        length: record.byteSize,
        repairable: true,
        action: .closeFinalMIMEBoundary,
        suggestion: suggestion(
          action: .closeFinalMIMEBoundary,
          original: "Multipart body is missing its final closing boundary.",
          change: "Append the final boundary only when the existing structure is unambiguous.",
          confidence: .medium,
          raw: true,
          metadataOnly: false
        )
      )
    } else if warning.contains("invalid Base64") {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .invalidBase64,
        severity: .warning,
        confidence: .high,
        title: "Invalid Base64",
        explanation: warning,
        offset: region.offset,
        length: record.byteSize,
        repairable: true,
        action: .preserveUndecodableBytesWithFallbackPreview,
        suggestion: suggestion(
          action: .preserveUndecodableBytesWithFallbackPreview,
          original: "Base64 content contains invalid characters.",
          change: "Preserve original bytes and use lenient preview metadata only.",
          confidence: .medium,
          raw: false,
          metadataOnly: true
        )
      )
    } else if warning.contains("malformed quoted-printable") {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .malformedQuotedPrintable,
        severity: .warning,
        confidence: .high,
        title: "Malformed quoted-printable",
        explanation: warning,
        offset: region.offset,
        length: record.byteSize,
        repairable: true,
        action: .preserveUndecodableBytesWithFallbackPreview
      )
    } else if warning.contains("unsupported transfer encoding") {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .unknownTransferEncoding,
        severity: .warning,
        confidence: .high,
        title: "Unknown transfer encoding",
        explanation: warning,
        offset: region.offset,
        length: record.byteSize,
        repairable: false,
        action: .inspectManually
      )
    }
  }

  if let transferEncoding,
    !["7bit", "8bit", "binary", "base64", "quoted-printable"].contains(transferEncoding)
  {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .unknownTransferEncoding,
      severity: .warning,
      confidence: .high,
      title: "Unknown transfer encoding",
      explanation: "Content-Transfer-Encoding is not one of the supported standard values.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually,
      evidence: ["encoding": transferEncoding]
    )
  }

  if let contentType {
    let lower = contentType.lowercased()
    if lower.contains("charset=") {
      let charset = parameter("charset", in: contentType).lowercased()
      let supported = [
        "utf-8", "utf8", "us-ascii", "ascii", "iso-8859-1", "latin1", "latin-1", "windows-1250",
        "cp1250", "windows-1252", "cp1252",
      ]
      if !charset.isEmpty && !supported.contains(charset) {
        context.appendIssue(
          sourceID: context.sourceID,
          message: record,
          kind: .invalidOrUnknownCharset,
          severity: .info,
          confidence: .medium,
          title: "Unknown charset",
          explanation: "The declared charset is not in Mail Surgeon's safe decode allowlist.",
          offset: region.offset,
          length: record.byteSize,
          repairable: true,
          action: .preserveUndecodableBytesWithFallbackPreview,
          evidence: ["charset": charset]
        )
      }
    }
    if lower.contains("text/plain"),
      bodyText.localizedCaseInsensitiveContains("<html")
        || bodyText.localizedCaseInsensitiveContains("<body")
    {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .contradictoryContentTypeAndBody,
        severity: .info,
        confidence: .medium,
        title: "Content-Type and body appear contradictory",
        explanation:
          "The message declares text/plain but the body resembles HTML. This can be a compatibility warning.",
        offset: region.offset,
        length: record.byteSize,
        repairable: false,
        action: .inspectManually
      )
    }
  }

  if contentType?.lowercased().contains("text/") == true,
    mimeMessage.safePlainTextPreview == nil,
    !parsed.body.isEmpty
  {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .declaredTextBodyUnavailable,
      severity: .warning,
      confidence: .medium,
      title: "Declared text body is unavailable",
      explanation: "The message declares text content but no safe preview could be decoded.",
      offset: region.offset,
      length: record.byteSize,
      repairable: true,
      action: .preserveUndecodableBytesWithFallbackPreview
    )
  }

  if String(data: parsed.body, encoding: .utf8) == nil,
    parsed.body.contains(where: { $0 >= 0x80 })
  {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .invalidUTF8Sequences,
      severity: .info,
      confidence: .medium,
      title: "Invalid UTF-8 sequences",
      explanation:
        "The body contains non-UTF-8 byte sequences. This may be normal for legacy encodings.",
      offset: parsed.bodyOffset,
      length: Int64(parsed.body.count),
      repairable: true,
      action: .preserveUndecodableBytesWithFallbackPreview
    )
  }

  analyzeMIMEPartTree(mimeMessage.root, region: region, record: record, context: &context)
}

private func analyzeMIMEPartTree(
  _ root: MIMEPart,
  region: MessageRegion,
  record: MailMessageRecord,
  context: inout ScanContext
) {
  var contentIDs: [String: Int] = [:]
  var referencedIDs: Set<String> = []

  func visit(_ part: MIMEPart) {
    if let contentID = part.contentID, !contentID.isEmpty {
      contentIDs[contentID, default: 0] += 1
    }
    if part.mediaType == "message/rfc822", part.children.isEmpty {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .embeddedMessageParseFailure,
        severity: .warning,
        confidence: .medium,
        title: "Embedded message parse failure",
        explanation: "A message/rfc822 part did not produce a child message.",
        offset: region.offset,
        length: record.byteSize,
        repairable: false,
        action: .inspectManually
      )
    }
    if part.disposition != nil,
      !["attachment", "inline"].contains(part.disposition ?? "")
    {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .invalidContentDisposition,
        severity: .warning,
        confidence: .high,
        title: "Invalid Content-Disposition",
        explanation: "A MIME part has a disposition outside attachment/inline.",
        offset: region.offset,
        length: record.byteSize,
        repairable: false,
        action: .inspectManually,
        evidence: ["disposition": part.disposition ?? ""]
      )
    }
    if let decoded = part.decodedBody {
      let sourceLength = max(1, region.raw.count)
      let ratio = Double(decoded.count) / Double(sourceLength)
      if ratio > context.policy.maxDecodedExpansionRatio {
        context.appendIssue(
          sourceID: context.sourceID,
          message: record,
          kind: .suspiciousDecodedExpansionRatio,
          severity: .warning,
          confidence: .medium,
          title: "Suspicious decoded expansion ratio",
          explanation: "Decoded part size is unexpectedly large compared with source bytes.",
          offset: region.offset,
          length: record.byteSize,
          repairable: false,
          action: .inspectManually,
          evidence: ["ratio": String(format: "%.2f", ratio)]
        )
      }
    }
    for child in part.children {
      visit(child)
    }
  }
  visit(root)

  for attachment in MIMEParser().parse(region.raw).attachments {
    let metadata = attachment.metadata
    if metadata.filename == nil || metadata.filename?.isEmpty == true {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .attachmentMissingFilename,
        severity: .info,
        confidence: .high,
        title: "Attachment has no filename",
        explanation: "A MIME attachment has no filename parameter.",
        offset: region.offset,
        length: record.byteSize,
        repairable: true,
        action: .sanitizeAttachmentFilename
      )
    } else if let filename = metadata.filename, context.policy.isUnsafeFilename(filename) {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .unsafeAttachmentFilename,
        severity: .warning,
        confidence: .high,
        title: "Attachment filename has unsafe path components",
        explanation: "Attachment filename contains path traversal or path separator characters.",
        offset: region.offset,
        length: record.byteSize,
        repairable: true,
        action: .sanitizeAttachmentFilename,
        evidence: ["sanitized": context.policy.sanitizedFilename(filename)],
        suggestion: suggestion(
          action: .sanitizeAttachmentFilename,
          original: "Unsafe attachment filename was declared.",
          change: "Use \(context.policy.sanitizedFilename(filename)) for export.",
          confidence: .high,
          raw: false,
          metadataOnly: true
        )
      )
    }
    if metadata.byteSize == 0 {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .zeroByteAttachment,
        severity: .info,
        confidence: .high,
        title: "Zero-byte attachment",
        explanation: "An attachment decoded to zero bytes.",
        offset: region.offset,
        length: record.byteSize,
        repairable: false,
        action: .inspectManually
      )
    }
    if let declaredSize = headerDeclaredSize(in: root),
      declaredSize != metadata.byteSize
    {
      context.appendIssue(
        sourceID: context.sourceID,
        message: record,
        kind: .attachmentDeclaredSizeMismatch,
        severity: .warning,
        confidence: .medium,
        title: "Attachment declared size mismatch",
        explanation: "A size parameter does not match the decoded attachment size.",
        offset: region.offset,
        length: record.byteSize,
        repairable: false,
        action: .inspectManually,
        evidence: ["declared": "\(declaredSize)", "decoded": "\(metadata.byteSize)"]
      )
    }
  }

  if let rawBody = String(data: region.raw, encoding: .isoLatin1) {
    let cidRegex = try? NSRegularExpression(pattern: #"cid:([^"'\s>]+)"#)
    let nsBody = rawBody as NSString
    let matches =
      cidRegex?.matches(in: rawBody, range: NSRange(location: 0, length: nsBody.length))
      ?? []
    for match in matches {
      referencedIDs.insert(nsBody.substring(with: match.range(at: 1)))
    }
  }

  for (contentID, count) in contentIDs where count > 1 {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .duplicateContentID,
      severity: .warning,
      confidence: .high,
      title: "Duplicate Content-ID",
      explanation: "More than one MIME part declares the same Content-ID.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually,
      evidence: ["contentIDHash": sha256Hex(Data(contentID.utf8)), "count": "\(count)"]
    )
  }
  for referenced in referencedIDs where contentIDs[referenced] == nil {
    context.appendIssue(
      sourceID: context.sourceID,
      message: record,
      kind: .referencedInlineContentIDNotFound,
      severity: .info,
      confidence: .medium,
      title: "Referenced inline Content-ID not found",
      explanation: "HTML references a cid: URL that was not found in MIME part Content-ID values.",
      offset: region.offset,
      length: record.byteSize,
      repairable: false,
      action: .inspectManually,
      evidence: ["contentIDHash": sha256Hex(Data(referenced.utf8))]
    )
  }
}

private func parseHeaderBlock(_ data: Data, baseOffset: UInt64) -> ParsedHeaderBlock {
  let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
  let lf = Data([0x0A, 0x0A])
  let separator = data.firstRange(of: crlf) ?? data.firstRange(of: lf)
  let headerData: Data
  let body: Data
  let bodyOffset: UInt64
  let hasTerminator: Bool
  if let separator {
    headerData = Data(data[..<separator.lowerBound])
    body = Data(data[separator.upperBound...])
    bodyOffset = baseOffset + UInt64(separator.upperBound)
    hasTerminator = true
  } else {
    headerData = data
    body = Data()
    bodyOffset = baseOffset + UInt64(data.count)
    hasTerminator = false
  }

  let hasBinary = headerData.contains { byte in
    byte < 0x09 || (byte > 0x0D && byte < 0x20) || byte == 0x7F
  }
  let raw = String(data: headerData, encoding: .isoLatin1) ?? ""
  var fields: [HeaderField] = []
  var malformed: [(String, UInt64)] = []
  var orphanFolded: [(String, UInt64)] = []
  var currentName: String?
  var runningOffset = baseOffset

  for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
    defer {
      runningOffset += UInt64(rawLine.utf8.count + 1)
    }
    guard !rawLine.isEmpty else { continue }
    if rawLine.first == " " || rawLine.first == "\t" {
      if currentName == nil {
        orphanFolded.append((rawLine, runningOffset))
      } else if let last = fields.indices.last {
        fields[last].value += " " + rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      continue
    }
    guard let colon = rawLine.firstIndex(of: ":") else {
      currentName = nil
      malformed.append((rawLine, runningOffset))
      continue
    }
    let name = String(rawLine[..<colon])
    let value = String(rawLine[rawLine.index(after: colon)...]).trimmingCharacters(
      in: .whitespaces)
    currentName = name
    fields.append(
      HeaderField(name: name, value: value, lineOffset: runningOffset, rawLine: rawLine))
  }

  return ParsedHeaderBlock(
    fields: fields,
    body: body,
    bodyOffset: bodyOffset,
    hasTerminator: hasTerminator,
    malformedLines: malformed,
    orphanFoldedLines: orphanFolded,
    hasBinaryBytes: hasBinary
  )
}

private func hasHeader(_ name: String, fields: [HeaderField]) -> Bool {
  headerValue(name, fields: fields) != nil
}

private func headerValue(_ name: String, fields: [HeaderField]) -> String? {
  fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
}

private func isValidMessageID(_ value: String) -> Bool {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.contains("@") else { return false }
  return !trimmed.contains(" ") && !trimmed.contains("\n") && trimmed.count >= 5
}

private func isValidFromDelimiter(_ line: Data) -> Bool {
  guard let text = String(data: line, encoding: .isoLatin1) else { return false }
  let pattern = #"^From \S+ .*\d{4}\s*$"#
  return text.range(of: pattern, options: .regularExpression) != nil
}

private func parameter(_ name: String, in header: String) -> String {
  for segment in header.split(separator: ";").dropFirst() {
    let pieces = segment.split(separator: "=", maxSplits: 1).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if pieces.count == 2, pieces[0].caseInsensitiveCompare(name) == .orderedSame {
      return pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
  }
  return ""
}

private func headerDeclaredSize(in part: MIMEPart) -> Int64? {
  if let value = part.parameters["size"], let size = Int64(value) {
    return size
  }
  if let value = part.dispositionParameters["size"], let size = Int64(value) {
    return size
  }
  for child in part.children {
    if let size = headerDeclaredSize(in: child) {
      return size
    }
  }
  return nil
}

private func suggestion(
  action: RecoverySuggestionAction,
  original: String,
  change: String,
  confidence: RecoveryConfidence,
  raw: Bool,
  metadataOnly: Bool
) -> RecoverySuggestion {
  let id = "sug-\(sha256Hex(Data("\(action.rawValue)|\(original)|\(change)".utf8)).prefix(24))"
  return RecoverySuggestion(
    id: id,
    issueID: "",
    action: action,
    originalCondition: original,
    proposedChange: change,
    confidence: confidence,
    changesRawBytes: raw,
    metadataOnly: metadataOnly,
    requiresUserConfirmation: true
  )
}

private func fileSize(_ url: URL) throws -> Int64 {
  ((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value)
    ?? 0
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

  fileprivate func trimmingLineEnding() -> Data {
    var end = endIndex
    if end > startIndex {
      let previous = index(before: end)
      if self[previous] == 0x0A { end = previous }
    }
    if end > startIndex {
      let previous = index(before: end)
      if self[previous] == 0x0D { end = previous }
    }
    return Data(self[startIndex..<end])
  }
}
