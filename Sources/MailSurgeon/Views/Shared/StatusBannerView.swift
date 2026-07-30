import SwiftUI

struct StatusBannerView: View {
  let message: String
  var systemImage = "info.circle"
  var role: Role = .info

  enum Role {
    case info
    case warning
    case error
  }

  var body: some View {
    Label(message, systemImage: systemImage)
      .font(.callout)
      .foregroundStyle(foregroundStyle)
      .lineLimit(3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .combine)
  }

  private var foregroundStyle: Color {
    switch role {
    case .info: .primary
    case .warning: .orange
    case .error: .red
    }
  }

  private var backgroundStyle: Color {
    switch role {
    case .info: Color.secondary.opacity(0.08)
    case .warning: Color.orange.opacity(0.12)
    case .error: Color.red.opacity(0.10)
    }
  }
}
