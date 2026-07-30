import SwiftUI

@main
struct MailSurgeonApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var appModel = AppModel()

  var body: some Scene {
    WindowGroup("Mail Surgeon") {
      ContentView()
        .environmentObject(appModel)
        .frame(minWidth: 900, minHeight: 620)
    }
    .defaultSize(width: 1180, height: 760)
    .windowStyle(.titleBar)
  }
}
