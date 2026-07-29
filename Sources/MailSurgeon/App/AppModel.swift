import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [MailSourceDescriptor] = []
    @Published var selectedSourceID: UUID?
    @Published var analysis: MailboxAnalysis = .empty
    @Published var isWorking = false
    @Published var statusMessage = "Přidej zdroj mailboxu."

    private let analyzer = MailAnalyzer()

    func addDemoSource(_ kind: MailSourceKind) {
        let source = MailSourceDescriptor(
            name: kind.defaultName,
            kind: kind,
            location: nil
        )
        sources.append(source)
        selectedSourceID = source.id
        statusMessage = "Přidán zdroj: \(source.name)"
    }

    func runDryAnalysis() async {
        guard let selectedSourceID,
              let source = sources.first(where: { $0.id == selectedSourceID }) else {
            statusMessage = "Nejdřív vyber zdroj."
            return
        }

        isWorking = true
        statusMessage = "Probíhá bezpečná analýza…"
        defer { isWorking = false }

        do {
            analysis = try await analyzer.analyze(source: source)
            statusMessage = "Analýza dokončena. Nebyly provedeny žádné změny."
        } catch {
            statusMessage = "Analýza selhala: \(error.localizedDescription)"
        }
    }
}
