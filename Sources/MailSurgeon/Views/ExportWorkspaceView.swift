import SwiftUI

struct ExportWorkspaceView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if model.selectedSourceID == nil {
          ContentUnavailableView(
            "Export není dostupný",
            systemImage: "square.and.arrow.up",
            description: Text("Nejdřív vyber zdroj a spusť recovery dry run.")
          )
        } else {
          reportsSection
          recoveredMailboxSection
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var reportsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Reporty", systemImage: "doc.text.magnifyingglass")
        .font(.headline)
      Text("JSON a Markdown reporty ve výchozím nastavení neobsahují těla zpráv.")
        .font(.callout)
        .foregroundStyle(.secondary)

      HStack(spacing: 10) {
        Button {
          Task { await model.exportRecoveryReportJSON() }
        } label: {
          Label("Exportovat JSON report", systemImage: "curlybraces")
        }
        .disabled(!model.canExportRecoveryReport)
        .accessibilityLabel("Exportovat JSON report")

        Button {
          Task { await model.exportRecoveryReportMarkdown() }
        } label: {
          Label("Exportovat Markdown report", systemImage: "doc.plaintext")
        }
        .disabled(!model.canExportRecoveryReport)
        .accessibilityLabel("Exportovat Markdown report")
      }

      reportStatus
    }
    .padding(14)
    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
  }

  private var recoveredMailboxSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Obnovený mailbox", systemImage: "archivebox")
        .font(.headline)

      DetailSectionView(
        title: "Stav exportu",
        rows: [
          "Zdroj": model.selectedSource?.name ?? "-",
          "Recovery report": model.recoveryReport == nil ? "Není připraven" : "Připraven",
          "Read-only": "Zdrojový mailbox se nikdy neupravuje.",
        ]
      )

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
        exportButton(.preserveAll, systemImage: "tray.full")
        exportButton(.deduplicated, systemImage: "doc.on.doc")
        exportButton(.recoverableOnly, systemImage: "wrench.adjustable")
      }

      if model.isRecoveryScanning {
        ProgressView(value: model.recoveryProgress.fractionCompleted)
          .accessibilityLabel("Průběh exportu nebo recovery operace")
      }

      StatusBannerView(message: model.statusMessage, systemImage: "info.circle")

      if let error = model.recoveryErrorMessage {
        StatusBannerView(message: error, systemImage: "exclamationmark.triangle", role: .error)
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var reportStatus: some View {
    if let report = model.recoveryReport {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
        MetricTileView(
          title: "Zprávy", value: "\(report.totalMessagesScanned)", systemImage: "envelope.open")
        MetricTileView(
          title: "Nálezy", value: "\(report.totalIssues)", systemImage: "exclamationmark.triangle")
        MetricTileView(
          title: "Výstup", value: "\(report.estimatedOutputMessageCount)", systemImage: "archivebox"
        )
      }
    } else {
      StatusBannerView(
        message: "Report bude dostupný po dokončení recovery dry runu.",
        systemImage: "stethoscope"
      )
    }
  }

  private func exportButton(_ mode: RecoveryExportMode, systemImage: String) -> some View {
    Button {
      Task { await model.exportRecoveryMBOX(mode: mode) }
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Label(mode.czechLabel, systemImage: systemImage)
          .font(.callout.weight(.semibold))
        Text(mode.czechDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
    .buttonStyle(.bordered)
    .disabled(!model.canExportRecoveryMBOX)
    .accessibilityLabel("Exportovat MBOX: \(mode.czechLabel)")
  }
}
