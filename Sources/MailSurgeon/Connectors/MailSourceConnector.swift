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
    case malformedArchive(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let detail): "Zatím není implementováno: \(detail)"
        case .accessDenied(let detail): "Přístup zamítnut: \(detail)"
        case .malformedArchive(let detail): "Poškozený nebo neznámý archiv: \(detail)"
        }
    }
}
