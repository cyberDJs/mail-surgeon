import Foundation

enum RecoverySeverity: String, CaseIterable, Codable, Identifiable, Sendable {
  case info
  case warning
  case error
  case critical

  var id: String { rawValue }

  var label: String {
    switch self {
    case .info: "Info"
    case .warning: "Warning"
    case .error: "Error"
    case .critical: "Critical"
    }
  }
}

enum RecoveryConfidence: String, CaseIterable, Codable, Sendable {
  case low
  case medium
  case high

  var label: String {
    switch self {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    }
  }
}

enum RecoveryIssueKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case missingMessageID
  case malformedMessageID
  case duplicateMessageID
  case missingDateHeader
  case invalidDateHeader
  case missingFromHeader
  case missingRecipientHeaders
  case malformedHeader
  case foldedHeaderWithoutParent
  case missingHeaderTerminator
  case binaryBytesInHeaders
  case missingMultipartBoundary
  case unterminatedMultipartBoundary
  case unknownTransferEncoding
  case invalidBase64
  case malformedQuotedPrintable
  case invalidOrUnknownCharset
  case missingContentType
  case contradictoryContentTypeAndBody
  case orphanMIMEPart
  case attachmentMissingFilename
  case unsafeAttachmentFilename
  case invalidContentDisposition
  case duplicateContentID
  case referencedInlineContentIDNotFound
  case embeddedMessageParseFailure
  case messageBeforeValidFromDelimiter
  case malformedFromSeparator
  case unescapedBodyFromLine
  case truncatedFinalMessage
  case zeroLengthMessage
  case invalidSourceOffsets
  case unexpectedGapBetweenMessages
  case exactDuplicateMessageHash
  case sameMessageIDDifferentHash
  case sameBodyDifferentTransportHeaders
  case zeroByteAttachment
  case attachmentDeclaredSizeMismatch
  case suspiciousDecodedExpansionRatio
  case invalidUTF8Sequences
  case declaredTextBodyUnavailable

  var id: String { rawValue }

  var label: String {
    rawValue
      .replacingOccurrences(
        of: "([a-z0-9])([A-Z])",
        with: "$1 $2",
        options: .regularExpression
      )
      .capitalized
  }
}

enum RecoverySuggestionAction: String, CaseIterable, Codable, Sendable {
  case generateDeterministicMessageID
  case normalizeLineEndings
  case addDefaultContentType
  case preserveUndecodableBytesWithFallbackPreview
  case sanitizeAttachmentFilename
  case closeFinalMIMEBoundary
  case removeDuplicateTransportCopyOnExport
  case preserveCanonicalDuplicate
  case reconstructFinalNewline
  case quarantineMessage
  case inspectManually
}

struct RecoverySuggestion: Identifiable, Codable, Equatable, Sendable {
  let id: String
  let issueID: String
  let action: RecoverySuggestionAction
  let originalCondition: String
  let proposedChange: String
  let confidence: RecoveryConfidence
  let changesRawBytes: Bool
  let metadataOnly: Bool
  let requiresUserConfirmation: Bool
}

struct RecoveryIssue: Identifiable, Codable, Equatable, Sendable {
  let id: String
  let sourceID: UUID
  let messageSummaryID: String?
  let kind: RecoveryIssueKind
  let severity: RecoverySeverity
  let confidence: RecoveryConfidence
  let title: String
  let technicalExplanation: String
  let byteOffset: UInt64?
  let byteLength: Int64?
  let isSafelyRepairable: Bool
  let suggestedAction: RecoverySuggestionAction
  let evidence: [String: String]

  var severitySortKey: Int {
    switch severity {
    case .critical: 0
    case .error: 1
    case .warning: 2
    case .info: 3
    }
  }

  var repairableLabel: String {
    isSafelyRepairable ? "Yes" : "No"
  }
}

enum RecoveryScanStatus: String, Codable, Sendable {
  case pending
  case running
  case completed
  case cancelled
  case failed
  case stale
}

struct RecoveryScanProgress: Equatable, Sendable {
  var status: RecoveryScanStatus
  var messagesScanned: Int
  var bytesScanned: Int64
  var totalBytes: Int64
  var issuesFound: Int
  var startedAt: Date?
  var completedAt: Date?
  var statusText: String

  var fractionCompleted: Double {
    guard totalBytes > 0 else { return 0 }
    return min(1, Double(bytesScanned) / Double(totalBytes))
  }

  var elapsedTime: TimeInterval {
    let start = startedAt ?? Date()
    return (completedAt ?? Date()).timeIntervalSince(start)
  }

  static let idle = RecoveryScanProgress(
    status: .pending,
    messagesScanned: 0,
    bytesScanned: 0,
    totalBytes: 0,
    issuesFound: 0,
    startedAt: nil,
    completedAt: nil,
    statusText: "Recovery scan is ready."
  )
}

struct RecoveryReport: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let sourceID: UUID
  let sourceName: String
  let sourceFingerprint: SourceFingerprint
  let scannerVersion: String
  let startedAt: Date
  let completedAt: Date
  let totalMessagesScanned: Int
  let totalBytesScanned: Int64
  let issues: [RecoveryIssue]
  let suggestions: [RecoverySuggestion]
  let estimatedOutputMessageCount: Int
  let estimatedRemovedDuplicateCount: Int
  let estimatedQuarantinedMessageCount: Int
  let estimatedOutputByteSize: Int64
  let privacyIncludesSubjectsSendersAndMessageIDs: Bool

  var totalIssues: Int { issues.count }

  var repairableIssueCount: Int {
    issues.filter(\.isSafelyRepairable).count
  }

  var nonRepairableIssueCount: Int {
    issues.count - repairableIssueCount
  }

  var countsBySeverity: [RecoverySeverity: Int] {
    Dictionary(grouping: issues, by: \.severity).mapValues(\.count)
  }

  var countsByKind: [RecoveryIssueKind: Int] {
    Dictionary(grouping: issues, by: \.kind).mapValues(\.count)
  }

  func jsonData(prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if prettyPrinted {
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    return try encoder.encode(self)
  }

  func markdown() -> String {
    var lines: [String] = [
      "# Mail Surgeon Recovery Report",
      "",
      "- Source: \(sourceName)",
      "- Source ID: \(sourceID.uuidString)",
      "- Scanner version: \(scannerVersion)",
      "- Started: \(Self.format(startedAt))",
      "- Completed: \(Self.format(completedAt))",
      "- Messages scanned: \(totalMessagesScanned)",
      "- Issues: \(totalIssues)",
      "- Repairable issues: \(repairableIssueCount)",
      "- Estimated output messages: \(estimatedOutputMessageCount)",
      "- Estimated removed duplicates: \(estimatedRemovedDuplicateCount)",
      "- Estimated quarantined messages: \(estimatedQuarantinedMessageCount)",
      "- Estimated output bytes: \(estimatedOutputByteSize)",
      "",
      "## Severity Counts",
      "",
    ]

    for severity in RecoverySeverity.allCases {
      lines.append("- \(severity.label): \(countsBySeverity[severity, default: 0])")
    }

    lines.append(contentsOf: ["", "## Issue Kind Counts", ""])
    for kind in RecoveryIssueKind.allCases where countsByKind[kind, default: 0] > 0 {
      lines.append("- \(kind.label): \(countsByKind[kind, default: 0])")
    }

    lines.append(contentsOf: ["", "## Issues", ""])
    for issue in issues {
      lines.append(
        "- \(issue.severity.label) / \(issue.confidence.label): \(issue.title) (`\(issue.kind.rawValue)`, `\(issue.id)`)"
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func format(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

enum RecoveryExportMode: String, CaseIterable, Identifiable, Sendable {
  case preserveAll
  case deduplicated
  case recoverableOnly

  var id: String { rawValue }

  var label: String {
    switch self {
    case .preserveAll: "Preserve all"
    case .deduplicated: "Deduplicated"
    case .recoverableOnly: "Recoverable only"
    }
  }
}

struct RecoveryExportResult: Equatable, Sendable {
  let outputURL: URL
  let quarantineURL: URL?
  let reportURL: URL
  let outputSHA256: String
  let exportedMessageCount: Int
  let quarantinedMessageCount: Int
  let excludedDuplicateCount: Int
}

enum RecoveryError: LocalizedError {
  case missingSourceLocation
  case unsupportedSourceKind
  case sourceAndDestinationMatch
  case unsafeDestination(URL)
  case unreadableSource(URL)
  case emptySource

  var errorDescription: String? {
    switch self {
    case .missingSourceLocation: "Recovery requires a source file location."
    case .unsupportedSourceKind: "Recovery currently supports MBOX sources only."
    case .sourceAndDestinationMatch: "Destination cannot be the source mailbox."
    case .unsafeDestination(let url):
      "Destination path is not safe for recovery export: \(url.path)"
    case .unreadableSource(let url): "Source mailbox is not readable: \(url.path)"
    case .emptySource: "Source mailbox contains no recoverable message regions."
    }
  }
}
