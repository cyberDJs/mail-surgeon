import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
  case messages
  case recovery
  case export

  var id: String { rawValue }

  var title: String {
    switch self {
    case .messages: "Zprávy"
    case .recovery: "Recovery"
    case .export: "Export"
    }
  }

  var systemImage: String {
    switch self {
    case .messages: "envelope"
    case .recovery: "stethoscope"
    case .export: "square.and.arrow.up"
    }
  }
}
