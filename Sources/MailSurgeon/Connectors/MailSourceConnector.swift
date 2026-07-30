import Foundation

protocol MailSourceConnector: Sendable {
  var descriptor: MailSourceDescriptor { get }
  func validateAccess() async throws
  func folders() async throws -> [String]
  func scanMessages() -> AsyncThrowingStream<MailMessageRecord, Error>
}

enum ConnectorError: LocalizedError {
  case notImplemented(String)
  case accessDenied(String)
  case missingFile(String)
  case unreadableFile(String)
  case emptyArchive(String)
  case malformedArchive(String)

  var errorDescription: String? {
    switch self {
    case .notImplemented(let detail): "Zatím není implementováno: \(detail)"
    case .accessDenied(let detail): "Přístup zamítnut: \(detail)"
    case .missingFile(let detail): "Soubor nebo složka neexistuje: \(detail)"
    case .unreadableFile(let detail): "Soubor nebo složku nelze číst: \(detail)"
    case .emptyArchive(let detail): "Archiv je prázdný: \(detail)"
    case .malformedArchive(let detail): "Poškozený nebo neznámý archiv: \(detail)"
    }
  }
}
