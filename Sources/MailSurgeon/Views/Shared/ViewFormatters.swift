import Foundation
import SwiftUI

enum ViewFormatters {
  static let dateTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  static func date(_ date: Date?) -> String {
    guard let date else { return "-" }
    return dateTime.string(from: date)
  }

  static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}

extension MailSourceKind {
  var systemImage: String {
    switch self {
    case .imap: "network"
    case .appleMail: "apple.logo"
    case .mbox: "archivebox"
    case .eml: "doc.text"
    case .maildir: "folder"
    }
  }
}

extension MessageSortDescriptor {
  var czechLabel: String {
    switch (column, ascending) {
    case (.date, false): "Nejnovější první"
    case (.date, true): "Nejstarší první"
    case (.sender, true): "Odesílatel A-Z"
    case (.sender, false): "Odesílatel Z-A"
    case (.subject, true): "Předmět A-Z"
    case (.subject, false): "Předmět Z-A"
    case (.size, true): "Velikost vzestupně"
    case (.size, false): "Velikost sestupně"
    case (.attachment, true): "Bez příloh první"
    case (.attachment, false): "S přílohami první"
    case (.category, true): "Kategorie A-Z"
    case (.category, false): "Kategorie Z-A"
    }
  }

  static let menuChoices: [MessageSortDescriptor] = [
    .init(column: .date, ascending: false),
    .init(column: .date, ascending: true),
    .init(column: .sender, ascending: true),
    .init(column: .sender, ascending: false),
    .init(column: .subject, ascending: true),
    .init(column: .subject, ascending: false),
    .init(column: .size, ascending: true),
    .init(column: .size, ascending: false),
    .init(column: .attachment, ascending: false),
    .init(column: .attachment, ascending: true),
    .init(column: .category, ascending: true),
    .init(column: .category, ascending: false),
  ]
}

extension RecoverySeverity {
  var czechLabel: String {
    switch self {
    case .info: "Info"
    case .warning: "Varování"
    case .error: "Chyba"
    case .critical: "Kritické"
    }
  }

  var systemImage: String {
    switch self {
    case .info: "info.circle"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.octagon"
    case .critical: "exclamationmark.octagon"
    }
  }
}

extension RecoveryConfidence {
  var czechLabel: String {
    switch self {
    case .low: "Nízká"
    case .medium: "Střední"
    case .high: "Vysoká"
    }
  }
}

extension RecoveryExportMode {
  var czechLabel: String {
    switch self {
    case .preserveAll: "Zachovat vše"
    case .deduplicated: "Bez duplicit"
    case .recoverableOnly: "Jen obnovitelné"
    }
  }

  var czechDescription: String {
    switch self {
    case .preserveAll: "Exportuje všechny zprávy a zachová transportní kopie."
    case .deduplicated: "Vynechá duplicitní transportní kopie podle recovery reportu."
    case .recoverableOnly: "Exportuje pouze zprávy označené jako bezpečně obnovitelné."
    }
  }
}
