import SwiftUI

struct SourceSidebarView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedSourceID: UUID?

  var body: some View {
    List(selection: $selectedSourceID) {
      Section("Zdroje") {
        if model.sources.isEmpty {
          Text("Žádné zdroje")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.sources) { source in
            SourceRowView(source: source, isSelected: selectedSourceID == source.id)
              .tag(source.id)
          }
        }
      }
    }
    .navigationTitle("Mail Surgeon")
    .accessibilityLabel("Seznam zdrojů")
    .toolbar {
      Menu {
        ForEach(MailSourceKind.allCases) { kind in
          Button {
            model.addSource(kind)
            selectedSourceID = model.selectedSourceID
          } label: {
            Label(kind.rawValue, systemImage: kind.systemImage)
          }
        }
      } label: {
        Label("Přidat zdroj", systemImage: "plus")
      }
      .help("Přidat zdroj mailboxu")
    }
  }
}

private struct SourceRowView: View {
  @EnvironmentObject private var model: AppModel
  let source: MailSourceDescriptor
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: source.kind.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(source.name)
          .lineLimit(1)
        Text(source.kind.rawValue)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      if isSelected {
        IndexStatusDot(status: model.indexProgress.status)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(isSelected ? "Vybráno" : "")
  }
}

private struct IndexStatusDot: View {
  let status: MailIndexStatus

  var body: some View {
    Image(systemName: systemImage)
      .foregroundStyle(color)
      .font(.caption)
      .accessibilityLabel("Stav indexu: \(status.label)")
  }

  private var systemImage: String {
    switch status {
    case .notIndexed: "circle"
    case .indexing: "circle.dotted"
    case .indexed: "checkmark.circle.fill"
    case .stale: "clock.badge.exclamationmark"
    case .failed: "exclamationmark.circle.fill"
    }
  }

  private var color: Color {
    switch status {
    case .notIndexed: .secondary
    case .indexing: .blue
    case .indexed: .green
    case .stale: .orange
    case .failed: .red
    }
  }
}
