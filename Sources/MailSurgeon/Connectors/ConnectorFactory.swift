import Foundation

struct ConnectorFactory {
    func makeConnector(for source: MailSourceDescriptor) -> any MailSourceConnector {
        switch source.kind {
        case .imap:
            PlaceholderConnector(descriptor: source, feature: "IMAP klient")
        case .appleMail:
            PlaceholderConnector(descriptor: source, feature: "Apple Mail reader")
        case .mbox:
            PlaceholderConnector(descriptor: source, feature: "MBOX parser")
        case .eml:
            PlaceholderConnector(descriptor: source, feature: "EML/EMLX parser")
        case .maildir:
            PlaceholderConnector(descriptor: source, feature: "Maildir reader")
        }
    }
}

struct PlaceholderConnector: MailSourceConnector {
    let descriptor: MailSourceDescriptor
    let feature: String

    func validateAccess() async throws { }

    func folders() async throws -> [String] {
        ["INBOX", "Sent", "Archive", "Trash"]
    }

    func scanMessages() -> AsyncThrowingStream<MailMessageRecord, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
