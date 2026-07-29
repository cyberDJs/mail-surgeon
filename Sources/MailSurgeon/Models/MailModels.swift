import Foundation

struct MailSourceDescriptor: Identifiable, Hashable {
    let id: UUID
    var name: String
    var kind: MailSourceKind
    var location: URL?

    init(id: UUID = UUID(), name: String, kind: MailSourceKind, location: URL?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
    }
}

enum MailSourceKind: String, CaseIterable, Identifiable {
    case imap = "IMAP"
    case appleMail = "Apple Mail"
    case mbox = "MBOX"
    case eml = "EML / EMLX"
    case maildir = "Maildir"

    var id: String { rawValue }

    var defaultName: String {
        switch self {
        case .imap: "Nový IMAP účet"
        case .appleMail: "Lokální Apple Mail"
        case .mbox: "Záloha MBOX"
        case .eml: "Soubory EML / EMLX"
        case .maildir: "Maildir archiv"
        }
    }
}

struct MailMessageRecord: Identifiable, Hashable {
    let id: UUID
    let sourceIdentifier: String
    let folderPath: String
    let messageID: String?
    let subject: String
    let sender: String
    let recipients: [String]
    let sentDate: Date?
    let byteSize: Int64
    let rawSHA256: String
    let hasAttachments: Bool
    let headers: [String: String]

    init(
        id: UUID = UUID(),
        sourceIdentifier: String,
        folderPath: String,
        messageID: String?,
        subject: String,
        sender: String,
        recipients: [String],
        sentDate: Date?,
        byteSize: Int64,
        rawSHA256: String,
        hasAttachments: Bool,
        headers: [String: String]
    ) {
        self.id = id
        self.sourceIdentifier = sourceIdentifier
        self.folderPath = folderPath
        self.messageID = messageID
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.sentDate = sentDate
        self.byteSize = byteSize
        self.rawSHA256 = rawSHA256
        self.hasAttachments = hasAttachments
        self.headers = headers
    }
}

struct MailboxAnalysis {
    var totalMessages: Int
    var totalBytes: Int64
    var exactDuplicates: Int
    var likelyNewsletters: Int
    var likelyOneTimeCodes: Int
    var largeMessages: Int
    var sensitiveCandidates: Int

    static let empty = MailboxAnalysis(
        totalMessages: 0,
        totalBytes: 0,
        exactDuplicates: 0,
        likelyNewsletters: 0,
        likelyOneTimeCodes: 0,
        largeMessages: 0,
        sensitiveCandidates: 0
    )
}

enum CleanupRecommendation: String, CaseIterable {
    case keep = "Ponechat"
    case archive = "Archivovat"
    case review = "Zkontrolovat"
    case quarantine = "Karanténa"
    case deleteCandidate = "Kandidát ke smazání"
}
