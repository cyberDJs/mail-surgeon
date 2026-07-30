import SwiftUI

struct MetricTileView: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
  }
}
