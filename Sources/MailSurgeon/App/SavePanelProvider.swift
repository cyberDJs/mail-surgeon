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
  func destination(for command: SavePanelCommand) async -> URL?
}

struct AppKitSavePanelProvider: SavePanelProviding {
  func destination(for command: SavePanelCommand) async -> URL? {
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

    UIActionLogger.debug("save panel requested: \(command.logIdentifier)")
    return await withCheckedContinuation { continuation in
      let bridge = SavePanelContinuation(continuation)
      let completion: (NSApplication.ModalResponse) -> Void = { response in
        Task { @MainActor in
          let selectedURL = response == .OK ? panel.url : nil
          if selectedURL == nil {
            UIActionLogger.debug("save panel cancelled: \(command.logIdentifier)")
          } else {
            UIActionLogger.debug("save panel completed: \(command.logIdentifier)")
          }
          bridge.resume(returning: selectedURL)
        }
      }

      if let window = NSApp.keyWindow
        ?? NSApp.mainWindow
        ?? NSApp.windows.first(where: { $0.isVisible })
      {
        panel.beginSheetModal(for: window, completionHandler: completion)
      } else {
        panel.begin(completionHandler: completion)
      }
    }
  }
}

extension SavePanelCommand {
  var logIdentifier: String {
    switch self {
    case .recoveryReportJSON: "recovery-json"
    case .recoveryReportMarkdown: "recovery-markdown"
    case .recoveryMBOX: "recovery-mbox"
    case .attachment: "attachment"
    }
  }
}

@MainActor
private final class SavePanelContinuation<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Never>?

  init(_ continuation: CheckedContinuation<Value, Never>) {
    self.continuation = continuation
  }

  func resume(returning value: Value) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(returning: value)
  }
}
