import SwiftUI

struct RecoveryWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var issueQuery = ""
  @State private var selectedIssueID: String?
  @State private var showsInspector = true

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      summary
      Divider()
      content
    }
    .searchable(text: $issueQuery, placement: .toolbar, prompt: "Hledat v nálezech")
    .task {
      issueQuery = model.recoveryIssueSearchText
      selectedIssueID = model.selectedRecoveryIssueID
    }
    .onChange(of: issueQuery) { _, value in
      model.recoveryIssueSearchText = value
    }
    .task(id: selectedIssueID) {
      model.selectRecoveryIssue(id: selectedIssueID)
    }
    .inspector(isPresented: $showsInspector) {
      RecoveryInspectorView()
        .inspectorColumnWidth(min: 260, ideal: 360, max: 520)
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button {
        model.startRecoveryDryRun()
      } label: {
        Label("Spustit dry run", systemImage: "stethoscope")
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.isRecoveryScanning || model.selectedSourceID == nil)
      .accessibilityLabel("Spustit recovery dry run")
      .help("Spustit read-only recovery analýzu")

      Button {
        model.cancelRecoveryScan()
      } label: {
        Label("Zrušit", systemImage: "xmark.circle")
      }
      .disabled(!model.isRecoveryScanning)
      .help("Bezpečně zrušit běžící scan")

      severityMenu
      issueKindMenu

      Spacer()

      Button {
        showsInspector.toggle()
      } label: {
        Label("Inspektor", systemImage: "sidebar.right")
      }
      .help("Zobrazit nebo skrýt inspektor nálezu")
    }
    .padding(12)
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.isRecoveryScanning {
        ProgressView(value: model.recoveryProgress.fractionCompleted)
          .accessibilityLabel("Průběh recovery scanu")
      }

      Text(model.recoveryProgress.statusText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      if let report = model.recoveryReport {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
          MetricTileView(
            title: "Zprávy", value: "\(report.totalMessagesScanned)", systemImage: "envelope.open")
          MetricTileView(
            title: "Nálezy", value: "\(report.totalIssues)", systemImage: "exclamationmark.triangle"
          )
          MetricTileView(
            title: "Opravitelné", value: "\(report.repairableIssueCount)",
            systemImage: "wrench.adjustable")
          MetricTileView(
            title: "Kritické", value: "\(report.countsBySeverity[.critical, default: 0])",
            systemImage: "exclamationmark.octagon")
        }
      }

      if let error = model.recoveryErrorMessage {
        StatusBannerView(message: error, systemImage: "exclamationmark.triangle", role: .error)
      }
    }
    .padding(12)
  }

  @ViewBuilder
  private var content: some View {
    if model.selectedSourceID == nil {
      ContentUnavailableView(
        "Vyber zdroj",
        systemImage: "tray",
        description: Text("Recovery dry run se spouští nad vybraným zdrojem read-only.")
      )
    } else if model.isRecoveryScanning {
      ContentUnavailableView(
        "Recovery scan běží",
        systemImage: "stethoscope",
        description: Text("Výsledky se zobrazí po dokončení nebo po zrušení.")
      )
    } else if model.recoveryReport == nil {
      ContentUnavailableView {
        Label("Recovery zatím neběželo", systemImage: "cross.case")
      } description: {
        Text("Spusť dry run. Zdrojový mailbox se nebude měnit.")
      } actions: {
        Button("Spustit dry run") {
          model.startRecoveryDryRun()
        }
        .disabled(model.selectedSourceID == nil)
      }
    } else if model.displayedRecoveryIssues.isEmpty {
      ContentUnavailableView(
        "Žádné nálezy",
        systemImage: "checkmark.seal",
        description: Text("Report nemá nálezy nebo jim neodpovídají aktivní filtry.")
      )
    } else {
      List(model.displayedRecoveryIssues, selection: $selectedIssueID) { issue in
        RecoveryIssueRowView(issue: issue)
          .tag(issue.id)
      }
      .listStyle(.inset)
      .accessibilityLabel("Seznam recovery nálezů")
    }
  }

  private var severityMenu: some View {
    Menu {
      Button("Vymazat filtry") {
        model.resetRecoveryFilters()
      }
      .disabled(model.enabledRecoverySeverities.isEmpty && model.selectedRecoveryIssueKind == nil)

      Divider()

      ForEach(RecoverySeverity.allCases) { severity in
        Button {
          model.setRecoverySeverity(
            severity,
            enabled: !model.enabledRecoverySeverities.contains(severity)
          )
        } label: {
          menuLabel(
            severity.czechLabel,
            checked: model.enabledRecoverySeverities.contains(severity)
          )
        }
      }
    } label: {
      Label(
        "Závažnost \(model.enabledRecoverySeverities.count)",
        systemImage: "exclamationmark.triangle")
    }
    .accessibilityLabel("Filtr závažnosti recovery nálezů")
  }

  private var issueKindMenu: some View {
    Menu {
      Button {
        model.selectedRecoveryIssueKind = nil
      } label: {
        menuLabel("Všechny typy", checked: model.selectedRecoveryIssueKind == nil)
      }

      Divider()

      ForEach(RecoveryIssueKind.allCases) { kind in
        if model.recoveryReport?.countsByKind[kind, default: 0] ?? 0 > 0 {
          Button {
            model.selectedRecoveryIssueKind = kind
          } label: {
            menuLabel(kind.label, checked: model.selectedRecoveryIssueKind == kind)
          }
        }
      }
    } label: {
      Label(model.selectedRecoveryIssueKind?.label ?? "Typ nálezu", systemImage: "tag")
    }
    .accessibilityLabel("Filtr typu recovery nálezu")
  }

  private func menuLabel(_ title: String, checked: Bool) -> some View {
    Label(title, systemImage: checked ? "checkmark" : " ")
  }
}
