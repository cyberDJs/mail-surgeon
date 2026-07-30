import SwiftUI

struct SourceHeaderView: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmsIndexDeletion = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Label(sourceTitle, systemImage: model.selectedSource?.kind.systemImage ?? "tray")
          .font(.headline)
          .lineLimit(1)
        Text(model.selectedSource?.kind.rawValue ?? "Bez zdroje")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
        indexMenu
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
        MetricTileView(title: "Zprávy", value: messageCount, systemImage: "envelope")
        MetricTileView(title: "Velikost", value: mailboxSize, systemImage: "externaldrive")
        MetricTileView(
          title: "Index", value: model.indexProgress.status.label, systemImage: "magnifyingglass")
        MetricTileView(title: "Stav", value: compactStatus, systemImage: "waveform.path.ecg")
      }

      if model.isIndexing {
        ProgressView()
          .accessibilityLabel("Průběh indexace")
      }

      if let error = model.indexErrorMessage {
        StatusBannerView(message: error, systemImage: "exclamationmark.triangle", role: .error)
      }
    }
    .padding(12)
    .confirmationDialog(
      "Smazat lokální index?",
      isPresented: $confirmsIndexDeletion,
      titleVisibility: .visible
    ) {
      Button("Smazat index", role: .destructive) {
        Task { await model.deleteIndexForSelectedSource() }
      }
      Button("Zrušit", role: .cancel) {}
    } message: {
      Text("Zdrojový mailbox zůstane beze změny. Smaže se jen lokální SQLite index.")
    }
  }

  private var sourceTitle: String {
    model.selectedSource?.name ?? "Vyber zdroj"
  }

  private var messageCount: String {
    if model.isIndexSearchActive {
      return "\(model.indexedResultTotal)"
    }
    return model.analysis.totalMessages > 0 ? "\(model.analysis.totalMessages)" : "-"
  }

  private var mailboxSize: String {
    model.analysis.totalBytes > 0 ? ViewFormatters.bytes(model.analysis.totalBytes) : "-"
  }

  private var compactStatus: String {
    if model.isIndexing { return "Indexuji" }
    if model.isLoadingMessages { return "Načítám" }
    if model.isRecoveryScanning { return "Recovery" }
    return model.statusMessage
  }

  private var indexMenu: some View {
    Menu {
      Button {
        Task { await model.buildIndexForSelectedSource() }
      } label: {
        Label("Vytvořit index", systemImage: "bolt.badge.magnifyingglass")
      }
      .disabled(model.isIndexing || model.selectedSourceID == nil)

      Button {
        Task { await model.buildIndexForSelectedSource(rebuild: true) }
      } label: {
        Label("Přestavět index", systemImage: "arrow.clockwise")
      }
      .disabled(model.isIndexing || model.selectedSourceID == nil)

      Divider()

      Button(role: .destructive) {
        confirmsIndexDeletion = true
      } label: {
        Label("Smazat index", systemImage: "trash")
      }
      .disabled(model.isIndexing || model.indexProgress.status == .notIndexed)
    } label: {
      Label("Index", systemImage: "externaldrive")
    }
    .help("Správa lokálního SQLite indexu")
  }
}
