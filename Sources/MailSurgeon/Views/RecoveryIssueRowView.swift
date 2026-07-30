import SwiftUI

struct RecoveryIssueRowView: View {
  let issue: RecoveryIssue

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: issue.severity.systemImage)
        .foregroundStyle(severityColor)
        .frame(width: 20)
        .accessibilityLabel(issue.severity.czechLabel)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(issue.severity.czechLabel)
            .font(.caption.weight(.semibold))
          Text(issue.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
        }
        Text(messageSummary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        HStack(spacing: 8) {
          Label(issue.confidence.czechLabel, systemImage: "gauge.with.dots.needle.33percent")
          Label(
            issue.isSafelyRepairable ? "Opravitelné" : "Neopravitelné",
            systemImage: issue.isSafelyRepairable ? "wrench.adjustable" : "lock")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .combine)
  }

  private var messageSummary: String {
    if let subject = issue.evidence["subject"], !subject.isEmpty {
      return subject
    }
    if let id = issue.messageSummaryID, !id.isEmpty {
      return id
    }
    return issue.evidence["senderHash"] ?? "Bez bezpečného identifikátoru"
  }

  private var severityColor: Color {
    switch issue.severity {
    case .info: .secondary
    case .warning: .orange
    case .error: .red
    case .critical: .purple
    }
  }
}
