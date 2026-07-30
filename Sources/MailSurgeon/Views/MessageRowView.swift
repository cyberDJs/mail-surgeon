import SwiftUI

struct MessageRowView: View {
  let record: MailMessageRecord

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(record.sender.isEmpty ? "(bez odesílatele)" : record.sender)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        Text(record.subject.isEmpty ? "(bez předmětu)" : record.subject)
          .font(.callout)
          .lineLimit(2)
          .truncationMode(.tail)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .trailing, spacing: 4) {
        Text(ViewFormatters.date(record.sentDate))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(ViewFormatters.bytes(record.byteSize))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        HStack(spacing: 6) {
          if record.hasAttachments {
            Image(systemName: "paperclip")
              .accessibilityLabel("Má přílohu")
          }
          Text(record.categoryLabel)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
        }
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .combine)
  }
}
