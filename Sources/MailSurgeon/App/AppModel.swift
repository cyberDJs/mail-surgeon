import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [MailSourceDescriptor] = []
    @Published var selectedSourceID: UUID?
    @Published var analysis: MailboxAnalysis = .empty
    @Published var progress: AnalysisProgress = .idle
    @Published var isWorking = false
    @Published var statusMessage = "Přidej zdroj mailboxu."
    @Published var messages: [MailMessageRecord] = []
    @Published var selectedMessageID: String?
    @Published var selectedMessageDetail: MessageDetail?
    @Published var messageSearchText = ""
    @Published var enabledMessageFilters: Set<MessageFilter> = []
    @Published var tableSortOrder: [KeyPathComparator<MailMessageRecord>] = [
        KeyPathComparator(\.sentDateSortKey, order: .reverse)
    ]
    @Published var browserErrorMessage: String?
    @Published var isLoadingMessages = false
    @Published var isLoadingDetail = false

    private let analyzer = MailAnalyzer()
    private let browser = MessageBrowser()
    private let bookmarkStore = SecurityScopedBookmarkStore()

    var selectedSource: MailSourceDescriptor? {
        guard let selectedSourceID else { return nil }
        return sources.first { $0.id == selectedSourceID }
    }

    var displayedMessages: [MailMessageRecord] {
        let filtered = browser.filter(
            records: messages,
            searchText: messageSearchText,
            enabledFilters: enabledMessageFilters
        )

        guard !tableSortOrder.isEmpty else { return filtered }
        return filtered.sorted(using: tableSortOrder)
    }

    var selectedMessage: MailMessageRecord? {
        guard let selectedMessageID else { return nil }
        return messages.first { $0.id == selectedMessageID }
    }

    init() {
        restoreBookmarkedSources()
    }

    func addSource(_ kind: MailSourceKind) {
        if kind == .mbox {
            addMBOXSource()
            return
        }

        let source = MailSourceDescriptor(
            name: kind.defaultName,
            kind: kind,
            location: nil
        )
        sources.append(source)
        selectedSourceID = source.id
        statusMessage = "Přidán zdroj: \(source.name)"
        resetBrowserState()
    }

    private func addMBOXSource() {
        let panel = NSOpenPanel()
        panel.title = "Vyber MBOX archiv"
        panel.message = "Vyber .mbox soubor nebo mailbox bundle složku. Mail Surgeon bude pouze číst."
        panel.prompt = "Vybrat"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        if let mboxType = UTType(filenameExtension: "mbox") {
            panel.allowedContentTypes = [mboxType]
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            statusMessage = "Výběr MBOX archivu byl zrušen."
            return
        }

        let source = MailSourceDescriptor(
            name: url.lastPathComponent,
            kind: .mbox,
            location: url
        )
        do {
            try bookmarkStore.saveBookmark(for: url, id: source.id)
            bookmarkStore.saveSourceRecord(BookmarkedSourceRecord(
                id: source.id,
                name: source.name,
                kind: source.kind
            ))
        } catch {
            statusMessage = "Bookmark pro MBOX nelze uložit: \(error.localizedDescription)"
        }
        sources.append(source)
        selectedSourceID = source.id
        analysis = .empty
        progress = .idle
        resetBrowserState()
        statusMessage = "Vybrán MBOX archiv: \(source.name)"
    }

    func loadMessagesForSelectedSource() async {
        guard let source = selectedSource else {
            statusMessage = "Nejdřív vyber zdroj."
            return
        }

        isLoadingMessages = true
        browserErrorMessage = nil
        resetBrowserState(keepMessages: false)
        progress = AnalysisProgress(
            messagesScanned: 0,
            bytesScanned: 0,
            status: "Načítám zprávy…"
        )
        statusMessage = progress.status
        defer { isLoadingMessages = false }

        do {
            messages = try await browser.loadSummaries(source: source) { [weak self] progress in
                self?.progress = progress
                self?.statusMessage = progress.status
            }
            analysis = analysis(from: messages)
            statusMessage = messages.isEmpty
                ? "Zdroj neobsahuje žádné zprávy."
                : "Zprávy načteny v read-only režimu."
            progress = AnalysisProgress(
                messagesScanned: messages.count,
                bytesScanned: messages.reduce(0) { $0 + $1.byteSize },
                status: statusMessage
            )
        } catch {
            browserErrorMessage = error.localizedDescription
            statusMessage = "Načtení zpráv selhalo: \(error.localizedDescription)"
        }
    }

    func loadSelectedMessageDetail() async {
        guard let record = selectedMessage else {
            selectedMessageDetail = nil
            return
        }

        isLoadingDetail = true
        selectedMessageDetail = nil
        defer { isLoadingDetail = false }

        do {
            selectedMessageDetail = try await browser.loadDetail(for: record)
        } catch {
            browserErrorMessage = error.localizedDescription
        }
    }

    func setFilter(_ filter: MessageFilter, enabled: Bool) {
        if enabled {
            enabledMessageFilters.insert(filter)
        } else {
            enabledMessageFilters.remove(filter)
        }
    }

    func runDryAnalysis() async {
        guard let selectedSourceID,
              let source = sources.first(where: { $0.id == selectedSourceID }) else {
            statusMessage = "Nejdřív vyber zdroj."
            return
        }

        isWorking = true
        analysis = .empty
        progress = AnalysisProgress(
            messagesScanned: 0,
            bytesScanned: 0,
            status: "Probíhá bezpečná analýza…"
        )
        statusMessage = progress.status
        defer { isWorking = false }

        do {
            analysis = try await analyzer.analyze(source: source) { [weak self] progress in
                self?.progress = progress
                self?.statusMessage = progress.status
            }
            statusMessage = "Analýza dokončena. Nebyly provedeny žádné změny."
            progress = AnalysisProgress(
                messagesScanned: analysis.totalMessages,
                bytesScanned: analysis.totalBytes,
                status: statusMessage
            )
        } catch {
            statusMessage = "Analýza selhala: \(error.localizedDescription)"
        }
    }

    private func restoreBookmarkedSources() {
        var restored: [MailSourceDescriptor] = []
        var staleCount = 0

        for record in bookmarkStore.sourceRecords() {
            guard let resolution = try? bookmarkStore.resolveBookmark(id: record.id) else { continue }
            if resolution.wasStale { staleCount += 1 }
            restored.append(MailSourceDescriptor(
                id: record.id,
                name: record.name,
                kind: record.kind,
                location: resolution.url
            ))
        }

        sources = restored
        selectedSourceID = restored.first?.id
        if !restored.isEmpty {
            statusMessage = staleCount > 0
                ? "Obnoveny MBOX zdroje a \(staleCount) stale bookmarků bylo obnoveno."
                : "Obnoveny uložené MBOX zdroje."
        }
    }

    private func resetBrowserState(keepMessages: Bool = false) {
        if !keepMessages { messages = [] }
        selectedMessageID = nil
        selectedMessageDetail = nil
        browserErrorMessage = nil
        messageSearchText = ""
        enabledMessageFilters = []
    }

    private func analysis(from records: [MailMessageRecord]) -> MailboxAnalysis {
        MailboxAnalysis(
            totalMessages: records.count,
            totalBytes: records.reduce(0) { $0 + $1.byteSize },
            exactDuplicates: records.filter { $0.classificationFlags.contains(.duplicate) }.count,
            likelyNewsletters: records.filter { $0.classificationFlags.contains(.newsletter) }.count,
            likelyOneTimeCodes: records.filter { $0.classificationFlags.contains(.oneTimeCode) }.count,
            largeMessages: records.filter { $0.classificationFlags.contains(.large) }.count,
            sensitiveCandidates: records.filter { $0.classificationFlags.contains(.sensitive) }.count
        )
    }
}
