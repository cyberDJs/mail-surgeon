import SwiftUI

struct SourceSidebarView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedSourceID: UUID?
  @State private var commandQueue = UICommandQueue<SourceUICommand>()

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
    .task(id: commandQueue.pendingCommand) {
      guard let pending = commandQueue.pendingCommand else { return }
      await execute(pending.command)
      commandQueue.complete(pending)
    }
    .toolbar {
      Menu {
        ForEach(MailSourceKind.allCases) { kind in
          Button {
            UIActionLogger.debug("source add command queued: \(kind.id)")
            commandQueue.queue(.addSource(kind))
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

  private func execute(_ command: SourceUICommand) async {
    switch command {
    case .addSource(let kind):
      let sourceID = await model.addSource(kind)
      if let sourceID {
        selectedSourceID = sourceID
      }
      UIActionLogger.debug("source add command completed: \(kind.id)")
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
