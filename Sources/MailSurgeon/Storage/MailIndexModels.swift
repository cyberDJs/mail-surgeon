import Foundation

enum MailIndexStatus: String, CaseIterable, Sendable {
  case notIndexed
  case indexing
  case indexed
  case stale
  case failed

  var label: String {
    switch self {
    case .notIndexed: "Neindexováno"
    case .indexing: "Indexuji"
    case .indexed: "Indexováno"
    case .stale: "Zastaralé"
    case .failed: "Selhalo"
    }
  }
}

struct MailIndexProgress: Equatable, Sendable {
  var status: MailIndexStatus
  var indexedMessages: Int
  var bytesIndexed: Int64
  var databaseSize: Int64
  var detail: String

  static let notIndexed = MailIndexProgress(
    status: .notIndexed,
    indexedMessages: 0,
    bytesIndexed: 0,
    databaseSize: 0,
    detail: "Index zatím nebyl vytvořen."
  )
}

struct SourceFingerprint: Equatable, Sendable {
  var fileSize: Int64
  var modificationDate: Date?
  var lightweightHash: String
}

struct IndexedSourceMetadata: Equatable, Sendable {
  var sourceID: UUID
  var name: String
  var path: String
  var fingerprint: SourceFingerprint
  var messageCount: Int
  var databaseSize: Int64
  var status: MailIndexStatus
}

struct MailIndexPage: Equatable, Sendable {
  var messages: [MailMessageRecord]
  var totalCount: Int
}
