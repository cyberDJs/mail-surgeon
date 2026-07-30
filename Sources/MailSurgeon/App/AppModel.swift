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

    private let analyzer = MailAnalyzer()

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
        sources.append(source)
        selectedSourceID = source.id
        analysis = .empty
        progress = .idle
        statusMessage = "Vybrán MBOX archiv: \(source.name)"
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
}
