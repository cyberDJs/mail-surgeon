import Foundation

struct MailSourceDescriptor: Identifiable, Hashable, Sendable {
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

enum MailSourceKind: String, CaseIterable, Identifiable, Codable, Sendable {
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

struct MailMessageRecord: Identifiable, Hashable, Sendable {
    var id: String { sourceIdentifier }
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
    let location: MessageStorageLocation?
    var classificationFlags: MessageClassificationFlags

    var sentDateSortKey: TimeInterval {
        sentDate?.timeIntervalSince1970 ?? 0
    }

    var attachmentSortKey: Int {
        hasAttachments ? 1 : 0
    }

    var categoryLabel: String {
        classificationFlags.displayLabel
    }

    init(
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
        headers: [String: String],
        location: MessageStorageLocation? = nil,
        classificationFlags: MessageClassificationFlags = []
    ) {
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
        self.location = location
        self.classificationFlags = classificationFlags
    }
}

struct MessageStorageLocation: Hashable, Sendable {
    let fileURL: URL
    let byteOffset: UInt64
    let byteLength: Int64
}

struct MessageClassificationFlags: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let duplicate = MessageClassificationFlags(rawValue: 1 << 0)
    static let newsletter = MessageClassificationFlags(rawValue: 1 << 1)
    static let oneTimeCode = MessageClassificationFlags(rawValue: 1 << 2)
    static let sensitive = MessageClassificationFlags(rawValue: 1 << 3)
    static let large = MessageClassificationFlags(rawValue: 1 << 4)

    var displayLabel: String {
        var labels: [String] = []
        if contains(.duplicate) { labels.append("Duplicitní") }
        if contains(.newsletter) { labels.append("Newsletter") }
        if contains(.oneTimeCode) { labels.append("OTP") }
        if contains(.sensitive) { labels.append("Citlivé") }
        if contains(.large) { labels.append("Velké") }
        return labels.isEmpty ? "Běžné" : labels.joined(separator: ", ")
    }
}

struct MessageDetail: Equatable, Sendable {
    let sourceIdentifier: String
    let headers: [String: String]
    let metadata: [String: String]
    let plainTextPreview: String?
    let rawByteSize: Int64
    let rawSHA256: String
}

enum MessageFilter: String, CaseIterable, Identifiable, Sendable {
    case duplicates = "Duplicity"
    case newsletters = "Newslettery"
    case oneTimeCodes = "OTP"
    case sensitive = "Citlivé"
    case large = "Velké"

    var id: String { rawValue }

    var flag: MessageClassificationFlags {
        switch self {
        case .duplicates: .duplicate
        case .newsletters: .newsletter
        case .oneTimeCodes: .oneTimeCode
        case .sensitive: .sensitive
        case .large: .large
        }
    }
}

enum MessageSortColumn: String, Sendable {
    case date
    case sender
    case subject
    case size
    case attachment
    case category
}

struct MessageSortDescriptor: Equatable, Sendable {
    var column: MessageSortColumn
    var ascending: Bool

    static let newestFirst = MessageSortDescriptor(column: .date, ascending: false)
}

struct MailboxAnalysis: Equatable, Sendable {
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

struct AnalysisProgress: Equatable, Sendable {
    var messagesScanned: Int
    var bytesScanned: Int64
    var status: String

    static let idle = AnalysisProgress(
        messagesScanned: 0,
        bytesScanned: 0,
        status: "Připraveno."
    )
}

enum CleanupRecommendation: String, CaseIterable, Sendable {
    case keep = "Ponechat"
    case archive = "Archivovat"
    case review = "Zkontrolovat"
    case quarantine = "Karanténa"
    case deleteCandidate = "Kandidát ke smazání"
}
