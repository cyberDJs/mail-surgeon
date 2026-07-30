import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol OpenPanelProviding {
  func selectMBOX() async -> URL?
}

struct AppKitOpenPanelProvider: OpenPanelProviding {
  func selectMBOX() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Vyber MBOX archiv"
    panel.message =
      "Vyber .mbox soubor nebo mailbox bundle složku. Mail Surgeon bude pouze číst."
    panel.prompt = "Vybrat"
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    if let mboxType = UTType(filenameExtension: "mbox") {
      panel.allowedContentTypes = [mboxType]
    }

    UIActionLogger.debug("source open panel requested")
    return await withCheckedContinuation { continuation in
      let bridge = PanelContinuation(continuation)
      let completion: (NSApplication.ModalResponse) -> Void = { response in
        Task { @MainActor in
          let selectedURL = response == .OK ? panel.url : nil
          if selectedURL == nil {
            UIActionLogger.debug("source open panel cancelled")
          } else {
            UIActionLogger.debug("source open panel completed")
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

@MainActor
private final class PanelContinuation<Value: Sendable> {
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
