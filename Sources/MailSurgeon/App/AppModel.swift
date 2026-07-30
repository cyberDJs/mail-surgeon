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
  @Published private(set) var messageSortDescriptor: MessageSortDescriptor = .newestFirst
  @Published var browserErrorMessage: String?
  @Published var isLoadingMessages = false
  @Published var isLoadingDetail = false
  @Published var indexProgress: MailIndexProgress = .notIndexed
  @Published var indexErrorMessage: String?
  @Published var isIndexing = false
  @Published var isIndexSearchActive = false
  @Published var indexedResultTotal = 0
  @Published var messagePageOffset = 0
  @Published var recoveryProgress: RecoveryScanProgress = .idle
  @Published var recoveryReport: RecoveryReport?
  @Published var recoveryErrorMessage: String?
  @Published var isRecoveryScanning = false
  @Published var recoveryIssueSearchText = ""
  @Published var enabledRecoverySeverities: Set<RecoverySeverity> = []
  @Published var selectedRecoveryIssueKind: RecoveryIssueKind?
  @Published var selectedRecoveryIssueID: String?
  @Published var recoveryIssueSortOrder: [KeyPathComparator<RecoveryIssue>] = [
    KeyPathComparator(\.severitySortKey)
  ]

  private let analyzer = MailAnalyzer()
  private let browser = MessageBrowser()
  private let bookmarkStore = SecurityScopedBookmarkStore()
  private let indexer = MailIndexingService()
  private let recoveryScanner = RecoveryScanner()
  private let recoveryExporter = RecoveryExportService()
  private let savePanelProvider: any SavePanelProviding
  private let searchQueryParser = SearchQueryParser()
  private var indexStore: MailIndexStore?
  private let messagePageLimit = 200
  private var recoveryTask: Task<Void, Never>?

  var selectedSource: MailSourceDescriptor? {
    guard let selectedSourceID else { return nil }
    return sources.first { $0.id == selectedSourceID }
  }

  var displayedMessages: [MailMessageRecord] {
    if isIndexSearchActive {
      return messages
    }

    let filtered = browser.filter(
      records: messages,
      searchText: messageSearchText,
      enabledFilters: enabledMessageFilters
    )

    return browser.sort(records: filtered, descriptor: messageSortDescriptor)
  }

  var selectedMessage: MailMessageRecord? {
    guard let selectedMessageID else { return nil }
    return messages.first { $0.id == selectedMessageID }
  }

  var displayedRecoveryIssues: [RecoveryIssue] {
    let trimmedSearch = recoveryIssueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = (recoveryReport?.issues ?? []).filter { issue in
      if !enabledRecoverySeverities.isEmpty,
        !enabledRecoverySeverities.contains(issue.severity)
      {
        return false
      }
      if let selectedRecoveryIssueKind, issue.kind != selectedRecoveryIssueKind {
        return false
      }
      if !trimmedSearch.isEmpty {
        let haystack = [
          issue.title,
          issue.technicalExplanation,
          issue.kind.label,
          issue.messageSummaryID ?? "",
        ].joined(separator: " ")
        if !haystack.localizedCaseInsensitiveContains(trimmedSearch) {
          return false
        }
      }
      return true
    }
    guard !recoveryIssueSortOrder.isEmpty else { return filtered }
    return filtered.sorted(using: recoveryIssueSortOrder)
  }

  var selectedRecoveryIssue: RecoveryIssue? {
    guard let selectedRecoveryIssueID else { return nil }
    return recoveryReport?.issues.first { $0.id == selectedRecoveryIssueID }
  }

  var selectedRecoverySuggestion: RecoverySuggestion? {
    guard let selectedRecoveryIssue else { return nil }
    return recoveryReport?.suggestions.first { $0.issueID == selectedRecoveryIssue.id }
  }

  var canExportRecoveryReport: Bool {
    recoveryReport != nil && !isRecoveryScanning
  }

  var canExportRecoveryMBOX: Bool {
    selectedSource != nil && recoveryReport != nil && !isRecoveryScanning
  }

  var canSaveSelectedAttachment: Bool {
    selectedMessage != nil && selectedMessageDetail != nil
  }

  init(savePanelProvider: any SavePanelProviding = AppKitSavePanelProvider()) {
    self.savePanelProvider = savePanelProvider
    indexStore = try? MailIndexStore(databaseURL: MailIndexStore.defaultDatabaseURL())
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
    indexProgress = .notIndexed
  }

  private func addMBOXSource() {
    let panel = NSOpenPanel()
    panel.title = "Vyber MBOX archiv"
    panel.message =
      "Vyber .mbox soubor nebo mailbox bundle složku. Mail Surgeon bude pouze číst."
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
      bookmarkStore.saveSourceRecord(
        BookmarkedSourceRecord(
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
    indexProgress = .notIndexed
    resetBrowserState()
    statusMessage = "Vybrán MBOX archiv: \(source.name)"
  }

  func loadMessagesForSelectedSource() async {
    guard let source = selectedSource else {
      statusMessage = "Nejdřív vyber zdroj."
      return
    }

    if canUseIndex {
      await refreshIndexedSearch(resetPage: true)
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
      statusMessage =
        messages.isEmpty
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

  func refreshIndexStatus() async {
    guard let source = selectedSource, let store = indexStore else {
      indexProgress = .notIndexed
      return
    }

    do {
      indexProgress = try await indexer.status(for: source, store: store)
      if indexProgress.status != .indexed {
        isIndexSearchActive = false
      }
    } catch {
      indexErrorMessage = error.localizedDescription
      indexProgress = MailIndexProgress(
        status: .failed,
        indexedMessages: 0,
        bytesIndexed: 0,
        databaseSize: 0,
        detail: error.localizedDescription
      )
    }
  }

  func buildIndexForSelectedSource(rebuild: Bool = false) async {
    guard let source = selectedSource else {
      statusMessage = "Nejdřív vyber zdroj."
      return
    }
    guard let store = indexStore else {
      statusMessage = "Index databázi nelze připravit."
      return
    }

    isIndexing = true
    indexErrorMessage = nil
    indexProgress = MailIndexProgress(
      status: .indexing,
      indexedMessages: 0,
      bytesIndexed: 0,
      databaseSize: indexProgress.databaseSize,
      detail: rebuild ? "Přestavuji index…" : "Vytvářím index…"
    )
    statusMessage = indexProgress.detail
    defer { isIndexing = false }

    do {
      try await indexer.buildIndex(for: source, store: store) { [weak self] progress in
        self?.indexProgress = progress
        self?.statusMessage = progress.detail
      }
      statusMessage = "Index je připraven."
      await refreshIndexedSearch(resetPage: true)
    } catch {
      indexErrorMessage = error.localizedDescription
      statusMessage = "Indexace selhala: \(error.localizedDescription)"
      await refreshIndexStatus()
    }
  }

  func deleteIndexForSelectedSource() async {
    guard let source = selectedSource else {
      statusMessage = "Nejdřív vyber zdroj."
      return
    }
    guard let store = indexStore else {
      statusMessage = "Index databázi nelze připravit."
      return
    }

    do {
      try await indexer.deleteIndex(for: source, store: store)
      indexProgress = .notIndexed
      isIndexSearchActive = false
      indexedResultTotal = 0
      messagePageOffset = 0
      resetBrowserState(keepMessages: false)
      statusMessage = "Index smazán. Zdrojový mailbox zůstal beze změny."
    } catch {
      indexErrorMessage = error.localizedDescription
      statusMessage = "Index nelze smazat: \(error.localizedDescription)"
    }
  }

  func refreshIndexedSearch(resetPage: Bool = false) async {
    guard canUseIndex, let source = selectedSource, let store = indexStore else { return }
    if resetPage { messagePageOffset = 0 }

    isLoadingMessages = true
    browserErrorMessage = nil
    defer { isLoadingMessages = false }

    do {
      let query = try searchQueryParser.parse(
        messageSearchText,
        enabledFilters: enabledMessageFilters
      )
      let page = try store.search(
        sourceID: source.id,
        query: query,
        sort: messageSortDescriptor,
        limit: messagePageLimit,
        offset: messagePageOffset
      )
      messages = page.messages
      indexedResultTotal = page.totalCount
      isIndexSearchActive = true
      analysis = analysis(from: messages)
      progress = AnalysisProgress(
        messagesScanned: page.totalCount,
        bytesScanned: messages.reduce(0) { $0 + $1.byteSize },
        status: "Výsledky z lokálního SQLite indexu."
      )
      statusMessage = "Vyhledávání běží přes lokální index."
    } catch {
      browserErrorMessage = error.localizedDescription
      statusMessage = "Vyhledávání v indexu selhalo: \(error.localizedDescription)"
    }
  }

  func nextMessagePage() async {
    guard canUseIndex, messagePageOffset + messagePageLimit < indexedResultTotal else { return }
    messagePageOffset += messagePageLimit
    await refreshIndexedSearch()
  }

  func previousMessagePage() async {
    guard canUseIndex, messagePageOffset > 0 else { return }
    messagePageOffset = max(0, messagePageOffset - messagePageLimit)
    await refreshIndexedSearch()
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

  func selectMessage(id: String?) {
    guard selectedMessageID != id else { return }
    selectedMessageID = id
    Task { @MainActor [weak self] in
      await Task.yield()
      await self?.loadSelectedMessageDetail()
    }
  }

  func selectRecoveryIssue(id: String?) {
    guard selectedRecoveryIssueID != id else { return }
    selectedRecoveryIssueID = id
  }

  func updateMessageSearchText(_ text: String) {
    guard messageSearchText != text else { return }
    messageSearchText = text
    if canUseIndex {
      Task { @MainActor [weak self] in
        await self?.refreshIndexedSearch(resetPage: true)
      }
    }
  }

  func updateMessageSortOrder(_ sortOrder: [KeyPathComparator<MailMessageRecord>]) {
    guard let descriptor = MessageSortDescriptor(sortOrder: sortOrder) else { return }
    updateMessageSortDescriptor(descriptor)
  }

  func updateMessageSortDescriptor(_ descriptor: MessageSortDescriptor) {
    guard messageSortDescriptor != descriptor else { return }
    messageSortDescriptor = descriptor
    tableSortOrder = descriptor.sortOrder
    if canUseIndex {
      Task { @MainActor [weak self] in
        await self?.refreshIndexedSearch(resetPage: true)
      }
    }
  }

  func saveAttachment(_ attachment: MessageAttachmentMetadata) async {
    guard let record = selectedMessage else {
      statusMessage = "Nejdřív vyber zprávu."
      return
    }

    let defaultName =
      attachment.displayName == "(bez názvu)"
      ? "attachment"
      : attachment.displayName

    guard
      let destination = savePanelProvider.destination(
        for: .attachment(defaultName: defaultName))
    else {
      statusMessage = "Uložení přílohy bylo zrušeno."
      return
    }

    do {
      let data = try await browser.loadAttachmentData(id: attachment.id, for: record)
      try data.write(to: destination, options: .atomic)
      statusMessage = "Příloha uložena: \(destination.lastPathComponent)"
    } catch {
      browserErrorMessage = error.localizedDescription
      statusMessage = "Přílohu nelze uložit: \(error.localizedDescription)"
    }
  }

  func setFilter(_ filter: MessageFilter, enabled: Bool) {
    if enabled {
      enabledMessageFilters.insert(filter)
    } else {
      enabledMessageFilters.remove(filter)
    }
    if canUseIndex {
      Task { await refreshIndexedSearch(resetPage: true) }
    }
  }

  func runDryAnalysis() async {
    await runRecoveryDryRun()
  }

  func startRecoveryDryRun() {
    recoveryTask?.cancel()
    recoveryTask = Task { [weak self] in
      await self?.runRecoveryDryRun()
    }
  }

  func runRecoveryDryRun() async {
    guard let selectedSourceID,
      let source = sources.first(where: { $0.id == selectedSourceID })
    else {
      statusMessage = "Nejdřív vyber zdroj."
      return
    }

    isWorking = true
    isRecoveryScanning = true
    recoveryErrorMessage = nil
    recoveryReport = nil
    analysis = .empty
    progress = AnalysisProgress(
      messagesScanned: 0,
      bytesScanned: 0,
      status: "Probíhá recovery dry run…"
    )
    recoveryProgress = RecoveryScanProgress(
      status: .running,
      messagesScanned: 0,
      bytesScanned: 0,
      totalBytes: 0,
      issuesFound: 0,
      startedAt: Date(),
      completedAt: nil,
      statusText: "Probíhá recovery dry run…"
    )
    statusMessage = progress.status
    defer {
      isWorking = false
      isRecoveryScanning = false
      recoveryTask = nil
    }

    do {
      let report = try await recoveryScanner.scan(source: source) { [weak self] recoveryProgress in
        self?.recoveryProgress = recoveryProgress
        self?.progress = AnalysisProgress(
          messagesScanned: recoveryProgress.messagesScanned,
          bytesScanned: recoveryProgress.bytesScanned,
          status: recoveryProgress.statusText
        )
        self?.statusMessage = recoveryProgress.statusText
      }
      recoveryReport = report
      try indexStore?.saveRecoveryReport(report)
      analysis = MailboxAnalysis(
        totalMessages: report.totalMessagesScanned,
        totalBytes: report.totalBytesScanned,
        exactDuplicates: report.estimatedRemovedDuplicateCount,
        likelyNewsletters: analysis.likelyNewsletters,
        likelyOneTimeCodes: analysis.likelyOneTimeCodes,
        largeMessages: analysis.largeMessages,
        sensitiveCandidates: analysis.sensitiveCandidates
      )
      statusMessage = "Recovery dry run dokončen. Zdrojový mailbox zůstal beze změny."
      progress = AnalysisProgress(
        messagesScanned: report.totalMessagesScanned,
        bytesScanned: report.totalBytesScanned,
        status: statusMessage
      )
    } catch is CancellationError {
      recoveryProgress.status = .cancelled
      statusMessage = "Recovery dry run byl zrušen. Zdrojový mailbox zůstal beze změny."
    } catch {
      recoveryErrorMessage = error.localizedDescription
      statusMessage = "Analýza selhala: \(error.localizedDescription)"
    }
  }

  func cancelRecoveryScan() {
    recoveryTask?.cancel()
    recoveryProgress.status = .cancelled
    statusMessage = "Recovery scan se ruší…"
  }

  func exportRecoveryReportJSON() {
    guard let recoveryReport else {
      statusMessage = "Nejdřív spusť recovery dry run."
      return
    }
    recoveryErrorMessage = nil
    guard let url = savePanelProvider.destination(for: .recoveryReportJSON) else { return }
    do {
      try recoveryReport.jsonData().write(to: url, options: .atomic)
      statusMessage = "Recovery JSON report uložen."
    } catch {
      recoveryErrorMessage = error.localizedDescription
      statusMessage = "Report nelze uložit: \(error.localizedDescription)"
    }
  }

  func exportRecoveryReportMarkdown() {
    guard let recoveryReport else {
      statusMessage = "Nejdřív spusť recovery dry run."
      return
    }
    recoveryErrorMessage = nil
    guard let url = savePanelProvider.destination(for: .recoveryReportMarkdown) else { return }
    do {
      try recoveryReport.markdown().write(to: url, atomically: true, encoding: .utf8)
      statusMessage = "Recovery Markdown report uložen."
    } catch {
      recoveryErrorMessage = error.localizedDescription
      statusMessage = "Report nelze uložit: \(error.localizedDescription)"
    }
  }

  func exportRecoveryMBOX(mode: RecoveryExportMode) async {
    guard let source = selectedSource, let recoveryReport else {
      statusMessage = "Nejdřív spusť recovery dry run."
      return
    }
    recoveryErrorMessage = nil
    guard
      let destination = savePanelProvider.destination(
        for: .recoveryMBOX(defaultName: "\(source.name)-recovered.mbox"))
    else { return }

    isRecoveryScanning = true
    defer { isRecoveryScanning = false }
    do {
      let result = try await recoveryExporter.export(
        source: source,
        report: recoveryReport,
        mode: mode,
        destination: destination
      ) { [weak self] progress in
        self?.recoveryProgress = progress
        self?.statusMessage = progress.statusText
      }
      statusMessage =
        "Recovery export hotov: \(result.exportedMessageCount) zpráv, SHA-256 \(String(result.outputSHA256.prefix(12)))."
    } catch {
      recoveryErrorMessage = error.localizedDescription
      statusMessage = "Recovery export selhal: \(error.localizedDescription)"
    }
  }

  private func restoreBookmarkedSources() {
    var restored: [MailSourceDescriptor] = []
    var staleCount = 0

    for record in bookmarkStore.sourceRecords() {
      guard let resolution = try? bookmarkStore.resolveBookmark(id: record.id) else {
        continue
      }
      if resolution.wasStale { staleCount += 1 }
      restored.append(
        MailSourceDescriptor(
          id: record.id,
          name: record.name,
          kind: record.kind,
          location: resolution.url
        ))
    }

    sources = restored
    selectedSourceID = restored.first?.id
    if !restored.isEmpty {
      statusMessage =
        staleCount > 0
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
    isIndexSearchActive = false
    indexedResultTotal = 0
    messagePageOffset = 0
  }

  private var canUseIndex: Bool {
    indexProgress.status == .indexed
  }

  private func analysis(from records: [MailMessageRecord]) -> MailboxAnalysis {
    MailboxAnalysis(
      totalMessages: records.count,
      totalBytes: records.reduce(0) { $0 + $1.byteSize },
      exactDuplicates: records.filter { $0.classificationFlags.contains(.duplicate) }.count,
      likelyNewsletters: records.filter { $0.classificationFlags.contains(.newsletter) }
        .count,
      likelyOneTimeCodes: records.filter { $0.classificationFlags.contains(.oneTimeCode) }
        .count,
      largeMessages: records.filter { $0.classificationFlags.contains(.large) }.count,
      sensitiveCandidates: records.filter { $0.classificationFlags.contains(.sensitive) }
        .count
    )
  }
}
