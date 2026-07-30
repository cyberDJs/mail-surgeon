import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowVisibilityObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    bringApplicationToForeground()
    focusExistingMainWindowOrObserve()

    DispatchQueue.main.async { [weak self] in
      self?.focusExistingMainWindowOrObserve()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    bringApplicationToForeground()
    focusExistingMainWindowOrObserve()
    return true
  }

  private func bringApplicationToForeground() {
    NSApp.activate(ignoringOtherApps: true)
  }

  private func focusExistingMainWindowOrObserve() {
    if let window = primaryApplicationWindow() {
      focus(window)
      removeWindowObserver()
      return
    }

    guard windowVisibilityObserver == nil else {
      return
    }

    windowVisibilityObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeMainNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self, let window = notification.object as? NSWindow else {
        return
      }

      Task { @MainActor in
        guard self.isPrimaryApplicationWindow(window) else {
          return
        }

        self.focus(window)
        self.removeWindowObserver()
      }
    }
  }

  private func primaryApplicationWindow() -> NSWindow? {
    if let keyWindow = NSApp.keyWindow, isPrimaryApplicationWindow(keyWindow) {
      return keyWindow
    }

    if let mainWindow = NSApp.mainWindow, isPrimaryApplicationWindow(mainWindow) {
      return mainWindow
    }

    return NSApp.windows.first(where: isPrimaryApplicationWindow)
  }

  private func isPrimaryApplicationWindow(_ window: NSWindow) -> Bool {
    window.canBecomeKey && !window.isMiniaturized && !window.isReleasedWhenClosed
  }

  private func focus(_ window: NSWindow) {
    window.title = "Mail Surgeon"
    window.contentMinSize = NSSize(width: 900, height: 620)
    window.makeKeyAndOrderFront(nil)
    bringApplicationToForeground()
  }

  private func removeWindowObserver() {
    guard let windowVisibilityObserver else {
      return
    }

    NotificationCenter.default.removeObserver(windowVisibilityObserver)
    self.windowVisibilityObserver = nil
  }
}
