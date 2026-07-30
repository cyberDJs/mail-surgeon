import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selectedSourceID: UUID?
  @State private var selectedSection: WorkspaceSection = .messages

  var body: some View {
    NavigationSplitView {
      SourceSidebarView(selectedSourceID: $selectedSourceID)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    } detail: {
      VStack(spacing: 0) {
        workspacePicker
        Divider()
        SourceHeaderView()
        Divider()
        workspace
      }
      .frame(minWidth: 620, minHeight: 520)
      .task {
        selectedSourceID = model.selectedSourceID
        await model.refreshIndexStatus()
      }
      .task(id: selectedSourceID) {
        await model.selectSource(id: selectedSourceID)
      }
    }
  }

  private var workspacePicker: some View {
    Picker("Pracovní oblast", selection: $selectedSection) {
      ForEach(WorkspaceSection.allCases) { section in
        Label(section.title, systemImage: section.systemImage).tag(section)
      }
    }
    .pickerStyle(.segmented)
    .padding([.horizontal, .top], 12)
    .padding(.bottom, 10)
    .accessibilityLabel("Výběr pracovní oblasti")
  }

  @ViewBuilder
  private var workspace: some View {
    switch selectedSection {
    case .messages:
      MessagesWorkspaceView()
    case .recovery:
      RecoveryWorkspaceView()
    case .export:
      ExportWorkspaceView()
    }
  }
}
