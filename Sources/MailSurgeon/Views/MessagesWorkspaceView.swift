import SwiftUI

struct MessagesWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var query = ""
  @State private var selectedMessageID: String?
  @State private var showsInspector = true

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      content
    }
    .searchable(text: $query, placement: .toolbar, prompt: "Hledat ve zprávách")
    .accessibilityLabel("Hledání ve zprávách")
    .task {
      query = model.messageSearchText
      selectedMessageID = model.selectedMessageID
    }
    .task(id: query) {
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await model.applyMessageSearchText(query)
    }
    .task(id: selectedMessageID) {
      await model.selectMessage(id: selectedMessageID)
    }
    .inspector(isPresented: $showsInspector) {
      MessageInspectorView()
        .inspectorColumnWidth(min: 260, ideal: 360, max: 520)
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button {
        Task { await model.loadMessagesForSelectedSource() }
      } label: {
        Label(loadButtonTitle, systemImage: "tray.and.arrow.down")
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.isLoadingMessages || model.selectedSourceID == nil)
      .help("Načíst přehled zpráv read-only")

      filterMenu
      sortMenu
      pagingControls

      Spacer()

      Button {
        showsInspector.toggle()
      } label: {
        Label("Inspektor", systemImage: "sidebar.right")
      }
      .help("Zobrazit nebo skrýt inspektor zprávy")
    }
    .padding(12)
  }

  @ViewBuilder
  private var content: some View {
    if model.selectedSourceID == nil {
      ContentUnavailableView(
        "Vyber zdroj",
        systemImage: "tray",
        description: Text("Zprávy se načítají až po výběru mailboxu.")
      )
    } else if model.isLoadingMessages {
      ProgressView(model.progress.status)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error = model.browserErrorMessage {
      ContentUnavailableView(
        "Zprávy nelze načíst",
        systemImage: "exclamationmark.triangle",
        description: Text(error)
      )
    } else if model.messages.isEmpty {
      ContentUnavailableView {
        Label("Zprávy nejsou načtené", systemImage: "tray")
      } description: {
        Text("Použij Načíst zprávy nebo vytvoř lokální index. Zdrojový mailbox se nemění.")
      } actions: {
        Button(loadButtonTitle) {
          Task { await model.loadMessagesForSelectedSource() }
        }
        .disabled(model.isLoadingMessages)
      }
    } else if model.displayedMessages.isEmpty {
      ContentUnavailableView(
        "Žádné shody",
        systemImage: "line.3.horizontal.decrease.circle",
        description: Text("Změň hledání, filtr nebo řazení.")
      )
    } else {
      List(model.displayedMessages, selection: $selectedMessageID) { record in
        MessageRowView(record: record)
          .tag(record.id)
      }
      .listStyle(.inset)
      .accessibilityLabel("Seznam zpráv")
    }
  }

  private var filterMenu: some View {
    Menu {
      Button("Vymazat filtry") {
        Task { await model.resetMessageFilters() }
      }
      .disabled(model.enabledMessageFilters.isEmpty)

      Divider()

      ForEach(MessageFilter.allCases) { filter in
        Button {
          Task {
            await model.applyFilter(
              filter,
              enabled: !model.enabledMessageFilters.contains(filter)
            )
          }
        } label: {
          Label(
            filter.rawValue,
            systemImage: model.enabledMessageFilters.contains(filter) ? "checkmark" : ""
          )
        }
      }
    } label: {
      Label(
        "Filtr \(model.enabledMessageFilters.count)",
        systemImage: "line.3.horizontal.decrease.circle")
    }
    .accessibilityLabel("Filtr zpráv")
    .help("Filtrovat zprávy podle existujících klasifikací")
  }

  private var sortMenu: some View {
    Menu {
      ForEach(MessageSortDescriptor.menuChoices, id: \.czechLabel) { descriptor in
        Button {
          Task { await model.applyMessageSortDescriptor(descriptor) }
        } label: {
          Label(
            descriptor.czechLabel,
            systemImage: descriptor == model.messageSortDescriptor ? "checkmark" : ""
          )
        }
      }
    } label: {
      Label(model.messageSortDescriptor.czechLabel, systemImage: "arrow.up.arrow.down")
    }
    .accessibilityLabel("Řazení zpráv")
    .help("Změnit řazení zpráv")
  }

  @ViewBuilder
  private var pagingControls: some View {
    if model.isIndexSearchActive {
      HStack(spacing: 6) {
        Text(pageLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Button {
          Task { await model.previousMessagePage() }
        } label: {
          Label("Předchozí", systemImage: "chevron.left")
            .labelStyle(.iconOnly)
        }
        .disabled(model.messagePageOffset == 0)
        .help("Předchozí stránka")

        Button {
          Task { await model.nextMessagePage() }
        } label: {
          Label("Další", systemImage: "chevron.right")
            .labelStyle(.iconOnly)
        }
        .disabled(model.messagePageOffset + model.messagePageLimit >= model.indexedResultTotal)
        .help("Další stránka")
      }
    }
  }

  private var loadButtonTitle: String {
    model.indexProgress.status == .indexed ? "Načíst z indexu" : "Načíst zprávy"
  }

  private var pageLabel: String {
    guard model.indexedResultTotal > 0 else { return "0 / 0" }
    let start = min(model.messagePageOffset + 1, model.indexedResultTotal)
    let end = min(model.messagePageOffset + model.messagePageLimit, model.indexedResultTotal)
    return "\(start)-\(end) / \(model.indexedResultTotal)"
  }
}
