import Foundation
import OSLog

enum UIActionLogger {
  private static let logger = Logger(
    subsystem: "com.cyberdjs.mailsurgeon",
    category: "UIActions"
  )

  static func debug(_ message: String) {
    #if DEBUG
      logger.debug("\(message, privacy: .public)")
    #endif
  }
}
