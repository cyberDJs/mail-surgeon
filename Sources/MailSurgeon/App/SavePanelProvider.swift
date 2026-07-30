import AppKit
import Foundation

enum SavePanelCommand: Hashable, Sendable {
  case recoveryReportJSON
  case recoveryReportMarkdown
  case recoveryMBOX(defaultName: String)
  case attachment(defaultName: String)
}

@MainActor
protocol SavePanelProviding {
  func destination(for command: SavePanelCommand) -> URL?
}

struct AppKitSavePanelProvider: SavePanelProviding {
  func destination(for command: SavePanelCommand) -> URL? {
    let panel = NSSavePanel()
    switch command {
    case .recoveryReportJSON:
      panel.title = "Export Recovery JSON"
      panel.message = "Report neobsahuje kompletní těla zpráv."
      panel.prompt = "Exportovat"
      panel.nameFieldStringValue = "recovery-report.json"
    case .recoveryReportMarkdown:
      panel.title = "Export Recovery Markdown"
      panel.message = "Report neobsahuje kompletní těla zpráv."
      panel.prompt = "Exportovat"
      panel.nameFieldStringValue = "recovery-report.md"
    case .recoveryMBOX(let defaultName):
      panel.title = "Export Recovery MBOX"
      panel.message = "Vyber nový cílový MBOX. Zdroj nebude přepsán."
      panel.prompt = "Exportovat"
      panel.nameFieldStringValue = defaultName
    case .attachment(let defaultName):
      panel.title = "Uložit přílohu"
      panel.message = "Vyber cílový soubor. Zdrojový mailbox zůstane beze změny."
      panel.prompt = "Uložit"
      panel.nameFieldStringValue = defaultName
    }

    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}
