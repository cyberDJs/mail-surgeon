import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var localMessageSearchText = ""
  @State private var localSelectedMessageID: String?
  @State private var localMessageSortOrder: [KeyPathComparator<MailMessageRecord>] = [
    KeyPathComparator(\.sentDateSortKey, order: .reverse)
  ]
  @State private var localSelectedRecoveryIssueID: String?
  @State private var localRecoveryIssueSortOrder: [KeyPathComparator<RecoveryIssue>] = [
    KeyPathComparator(\.severitySortKey)
  ]
  @State private var searchUpdateTask: Task<Void, Never>?

  var body: some View {
    NavigationSplitView {
      List(selection: $model.selectedSourceID) {
        Section("Zdroje") {
          ForEach(model.sources) { source in
            Label(source.name, systemImage: icon(for: source.kind))
              .tag(source.id)
          }
        }
      }
      .navigationTitle("Mail Surgeon")
      .toolbar {
        Menu {
          ForEach(MailSourceKind.allCases) { kind in
            Button(kind.rawValue) { model.addSource(kind) }
          }
        } label: {
          Label("Přidat zdroj", systemImage: "plus")
        }
      }
    } detail: {
      VStack(alignment: .leading, spacing: 16) {
        header
        progressSummary
        indexSummary
        recoverySection
        analysisGrid
        browserWorkspace
        footer
      }
      .padding(24)
      .onChange(of: model.selectedSourceID) { _, _ in
        model.messages = []
        model.selectedMessageID = nil
        model.selectedMessageDetail = nil
        localSelectedMessageID = nil
        localMessageSearchText = ""
        Task { await model.refreshIndexStatus() }
      }
      .task {
        localMessageSearchText = model.messageSearchText
        localSelectedMessageID = model.selectedMessageID
        localMessageSortOrder = model.tableSortOrder
        localSelectedRecoveryIssueID = model.selectedRecoveryIssueID
        localRecoveryIssueSortOrder = model.recoveryIssueSortOrder
        await model.refreshIndexStatus()
      }
    }
  }

  private var progressSummary: some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.isWorking {
        ProgressView()
          .controlSize(.small)
      }
      HStack(spacing: 18) {
        Label("\(model.progress.messagesScanned) zpráv", systemImage: "envelope.open")
        Label(
          ByteCountFormatter.string(
            fromByteCount: model.progress.bytesScanned, countStyle: .file),
          systemImage: "doc.text.magnifyingglass")
        Text(model.progress.status)
          .foregroundStyle(.secondary)
      }
      .font(.callout)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Bezpečná analýza a migrace mailboxů")
        .font(.largeTitle.bold())
      Text("IMAP, Apple Mail, MBOX, EML/EMLX a Maildir. Výchozí režim nic nemaže.")
        .foregroundStyle(.secondary)
    }
  }

  private var indexSummary: some View {
    HStack(spacing: 14) {
      Label(model.indexProgress.status.label, systemImage: "externaldrive.badge.magnifyingglass")
        .font(.callout.weight(.medium))

      if model.isIndexing {
        ProgressView()
          .controlSize(.small)
      }

      Text("\(model.indexProgress.indexedMessages) indexovaných")
        .foregroundStyle(.secondary)
      Text(
        ByteCountFormatter.string(
          fromByteCount: model.indexProgress.databaseSize,
          countStyle: .file
        )
      )
      .foregroundStyle(.secondary)

      if model.isIndexSearchActive {
        Text(
          "\(model.messagePageOffset + 1)-\(min(model.messagePageOffset + 200, model.indexedResultTotal)) / \(model.indexedResultTotal)"
        )
        .foregroundStyle(.secondary)
        Button {
          Task { await model.previousMessagePage() }
        } label: {
          Label("Předchozí", systemImage: "chevron.left")
            .labelStyle(.iconOnly)
        }
        .help("Předchozí stránka")
        .disabled(model.messagePageOffset == 0)

        Button {
          Task { await model.nextMessagePage() }
        } label: {
          Label("Další", systemImage: "chevron.right")
            .labelStyle(.iconOnly)
        }
        .help("Další stránka")
        .disabled(model.messagePageOffset + 200 >= model.indexedResultTotal)
      }

      Spacer()

      Button {
        Task { await model.buildIndexForSelectedSource() }
      } label: {
        Label("Build Index", systemImage: "bolt.badge.magnifyingglass")
      }
      .buttonStyle(.bordered)
      .disabled(model.isIndexing || model.selectedSourceID == nil)

      Button {
        Task { await model.buildIndexForSelectedSource(rebuild: true) }
      } label: {
        Label("Rebuild Index", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .disabled(model.isIndexing || model.selectedSourceID == nil)

      Button(role: .destructive) {
        Task { await model.deleteIndexForSelectedSource() }
      } label: {
        Label("Delete Index", systemImage: "trash")
      }
      .buttonStyle(.bordered)
      .disabled(model.isIndexing || model.indexProgress.status == .notIndexed)
    }
    .font(.callout)
  }

  private var analysisGrid: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 18) {
      GridRow {
        metric("Zprávy", value: "\(model.analysis.totalMessages)", icon: "envelope")
        metric(
          "Velikost",
          value: ByteCountFormatter.string(
            fromByteCount: model.analysis.totalBytes, countStyle: .file),
          icon: "externaldrive")
        metric("Duplicity", value: "\(model.analysis.exactDuplicates)", icon: "doc.on.doc")
      }
      GridRow {
        metric(
          "Newslettery", value: "\(model.analysis.likelyNewsletters)", icon: "megaphone")
        metric("OTP", value: "\(model.analysis.likelyOneTimeCodes)", icon: "number.square")
        metric(
          "Citlivé", value: "\(model.analysis.sensitiveCandidates)", icon: "lock.shield")
      }
      GridRow {
        metric("Velké zprávy", value: "\(model.analysis.largeMessages)", icon: "tray.full")
        Color.clear
        Color.clear
      }
    }
  }

  private var recoverySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Label("Recovery", systemImage: "cross.case")
          .font(.headline)
        if model.isRecoveryScanning {
          ProgressView(value: model.recoveryProgress.fractionCompleted)
            .frame(width: 160)
        }
        Text(model.recoveryProgress.statusText)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button {
          model.startRecoveryDryRun()
        } label: {
          Label("Dry Run", systemImage: "stethoscope")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isRecoveryScanning || model.selectedSourceID == nil)

        Button {
          model.cancelRecoveryScan()
        } label: {
          Label("Cancel", systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
        .disabled(!model.isRecoveryScanning)
      }

      if let report = model.recoveryReport {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
          GridRow {
            metric("Scanned", value: "\(report.totalMessagesScanned)", icon: "envelope.open")
            metric("Issues", value: "\(report.totalIssues)", icon: "exclamationmark.triangle")
            metric("Repairable", value: "\(report.repairableIssueCount)", icon: "wrench.adjustable")
            metric("Non-repairable", value: "\(report.nonRepairableIssueCount)", icon: "lock")
          }
          GridRow {
            metric(
              "Critical",
              value: "\(report.countsBySeverity[.critical, default: 0])",
              icon: "exclamationmark.octagon"
            )
            metric(
              "Errors",
              value: "\(report.countsBySeverity[.error, default: 0])",
              icon: "xmark.octagon"
            )
            metric(
              "Warnings",
              value: "\(report.countsBySeverity[.warning, default: 0])",
              icon: "exclamationmark.triangle"
            )
            metric(
              "Info",
              value: "\(report.countsBySeverity[.info, default: 0])",
              icon: "info.circle"
            )
          }
        }

        if let error = model.recoveryErrorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(.callout)
        }

        recoveryToolbar(report: report)

        HSplitView {
          recoveryIssueTable
            .frame(minWidth: 620, minHeight: 220)
          recoveryIssueDetail
            .frame(minWidth: 320, minHeight: 220)
        }
        .frame(height: 280)
      } else if let error = model.recoveryErrorMessage {
        ContentUnavailableView(
          "Recovery scan failed",
          systemImage: "exclamationmark.triangle",
          description: Text(error)
        )
        .frame(height: 110)
      }
    }
  }

  private func recoveryToolbar(report: RecoveryReport) -> some View {
    HStack(spacing: 10) {
      TextField("Search issues", text: $model.recoveryIssueSearchText)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 180)

      ForEach(RecoverySeverity.allCases) { severity in
        Toggle(
          severity.label,
          isOn: Binding(
            get: { model.enabledRecoverySeverities.contains(severity) },
            set: { enabled in
              if enabled {
                model.enabledRecoverySeverities.insert(severity)
              } else {
                model.enabledRecoverySeverities.remove(severity)
              }
            }
          )
        )
        .toggleStyle(.checkbox)
      }

      Picker("Issue Type", selection: $model.selectedRecoveryIssueKind) {
        Text("All Types").tag(Optional<RecoveryIssueKind>.none)
        ForEach(RecoveryIssueKind.allCases) { kind in
          if report.countsByKind[kind, default: 0] > 0 {
            Text(kind.label).tag(Optional(kind))
          }
        }
      }
      .frame(width: 220)

      Spacer()

      Menu {
        Button("Preserve all") {
          Task { await model.exportRecoveryMBOX(mode: .preserveAll) }
        }
        Button("Deduplicated") {
          Task { await model.exportRecoveryMBOX(mode: .deduplicated) }
        }
        Button("Recoverable only") {
          Task { await model.exportRecoveryMBOX(mode: .recoverableOnly) }
        }
      } label: {
        Label("Export MBOX", systemImage: "square.and.arrow.up")
      }
      .disabled(!model.canExportRecoveryMBOX)

      Button {
        model.exportRecoveryReportJSON()
      } label: {
        Label("JSON", systemImage: "curlybraces")
      }
      .buttonStyle(.bordered)
      .disabled(!model.canExportRecoveryReport)

      Button {
        model.exportRecoveryReportMarkdown()
      } label: {
        Label("Markdown", systemImage: "doc.plaintext")
      }
      .buttonStyle(.bordered)
      .disabled(!model.canExportRecoveryReport)
    }
    .font(.callout)
  }

  @ViewBuilder
  private var recoveryIssueTable: some View {
    if model.displayedRecoveryIssues.isEmpty {
      ContentUnavailableView(
        "No recovery issues",
        systemImage: "checkmark.seal",
        description: Text("No issues match the current recovery filters.")
      )
    } else {
      Table(
        model.displayedRecoveryIssues,
        selection: recoverySelectionBinding,
        sortOrder: recoverySortBinding
      ) {
        TableColumn("Severity", value: \.severitySortKey) { issue in
          Text(issue.severity.label)
        }
        .width(min: 80, ideal: 90)

        TableColumn("Message date") { issue in
          Text(
            issue.evidence["messageDate"]?.isEmpty == false ? issue.evidence["messageDate"]! : "-"
          )
          .lineLimit(1)
        }
        .width(min: 120, ideal: 160)

        TableColumn("Sender") { issue in
          Text(issue.evidence["sender"] ?? issue.evidence["senderHash"]?.prefixText ?? "-")
            .lineLimit(1)
        }
        .width(min: 120, ideal: 180)

        TableColumn("Subject") { issue in
          Text(issue.evidence["subject"] ?? issue.evidence["subjectHash"]?.prefixText ?? "-")
            .lineLimit(1)
        }
        .width(min: 140, ideal: 240)

        TableColumn("Issue") { issue in
          Text(issue.title)
            .lineLimit(1)
        }
        .width(min: 180, ideal: 260)

        TableColumn("Confidence") { issue in
          Text(issue.confidence.label)
        }
        .width(min: 90, ideal: 100)

        TableColumn("Repairable", value: \.repairableLabel) { issue in
          Text(issue.repairableLabel)
        }
        .width(min: 80, ideal: 90)
      }
    }
  }

  @ViewBuilder
  private var recoveryIssueDetail: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Recovery Inspector")
        .font(.headline)
      if let issue = model.selectedRecoveryIssue {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            detailSection(
              "Issue",
              rows: [
                "ID": issue.id,
                "Kind": issue.kind.rawValue,
                "Severity": issue.severity.label,
                "Confidence": issue.confidence.label,
                "Repairable": issue.repairableLabel,
                "Action": issue.suggestedAction.rawValue,
                "Offset": issue.byteOffset.map(String.init) ?? "",
                "Length": issue.byteLength.map(String.init) ?? "",
              ])
            detailSection(
              "Explanation",
              rows: [
                "Title": issue.title,
                "Technical": issue.technicalExplanation,
              ])
            detailSection("Evidence", rows: issue.evidence)
            if let suggestion = model.selectedRecoverySuggestion {
              detailSection(
                "Proposed Repair",
                rows: [
                  "Action": suggestion.action.rawValue,
                  "Original": suggestion.originalCondition,
                  "Change": suggestion.proposedChange,
                  "Confidence": suggestion.confidence.label,
                  "Changes raw bytes": suggestion.changesRawBytes ? "Yes" : "No",
                  "Metadata only": suggestion.metadataOnly ? "Yes" : "No",
                  "Requires confirmation": suggestion.requiresUserConfirmation ? "Yes" : "No",
                ])
            }
          }
          .textSelection(.enabled)
        }
      } else {
        ContentUnavailableView(
          "Select an issue",
          systemImage: "list.bullet.rectangle",
          description: Text("Recovery details appear after selecting an issue.")
        )
      }
    }
  }

  private var browserWorkspace: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 12) {
        browserToolbar
        browserContent
      }
      .frame(minWidth: 560)

      detailPane
        .frame(minWidth: 320)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var browserToolbar: some View {
    HStack(spacing: 12) {
      TextField("Hledat", text: $localMessageSearchText)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 220)
        .onChange(of: localMessageSearchText) { _, newValue in
          scheduleSearchUpdate(newValue)
        }

      ForEach(MessageFilter.allCases) { filter in
        Toggle(
          filter.rawValue,
          isOn: Binding(
            get: { model.enabledMessageFilters.contains(filter) },
            set: { model.setFilter(filter, enabled: $0) }
          )
        )
        .toggleStyle(.checkbox)
      }

      Spacer()

      Button {
        Task { await model.loadMessagesForSelectedSource() }
      } label: {
        Label(
          model.indexProgress.status == .indexed ? "Načíst z indexu" : "Načíst zprávy",
          systemImage: "tray.and.arrow.down"
        )
      }
      .buttonStyle(.bordered)
      .disabled(model.isLoadingMessages || model.selectedSourceID == nil)
    }
  }

  @ViewBuilder
  private var browserContent: some View {
    if model.isLoadingMessages {
      VStack(spacing: 12) {
        ProgressView()
        Text(model.progress.status)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error = model.browserErrorMessage {
      ContentUnavailableView(
        "Zprávy nelze načíst",
        systemImage: "exclamationmark.triangle",
        description: Text(error)
      )
    } else if model.messages.isEmpty {
      ContentUnavailableView(
        "Žádné zprávy",
        systemImage: "tray",
        description: Text("Vybraný zdroj zatím nemá načtený přehled.")
      )
    } else if model.displayedMessages.isEmpty {
      ContentUnavailableView(
        "Nic neodpovídá",
        systemImage: "line.3.horizontal.decrease.circle",
        description: Text("Změň hledání nebo filtr.")
      )
    } else {
      Table(
        model.displayedMessages, selection: messageSelectionBinding,
        sortOrder: messageSortBinding
      ) {
        TableColumn("Date", value: \.sentDateSortKey) { record in
          Text(formatDate(record.sentDate))
        }
        .width(min: 140, ideal: 170)

        TableColumn("Sender", value: \.sender) { record in
          Text(record.sender.isEmpty ? "(bez odesílatele)" : record.sender)
            .lineLimit(1)
        }
        .width(min: 160, ideal: 220)

        TableColumn("Subject", value: \.subject) { record in
          Text(record.subject)
            .lineLimit(1)
        }
        .width(min: 240, ideal: 360)

        TableColumn("Size", value: \.byteSize) { record in
          Text(
            ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file)
          )
          .monospacedDigit()
        }
        .width(min: 90, ideal: 110)

        TableColumn("Attachment", value: \.attachmentSortKey) { record in
          Image(systemName: record.hasAttachments ? "paperclip" : "minus")
            .foregroundStyle(record.hasAttachments ? .primary : .secondary)
        }
        .width(min: 90, ideal: 110)

        TableColumn("Category", value: \.categoryLabel) { record in
          Text(record.categoryLabel)
            .lineLimit(1)
        }
        .width(min: 120, ideal: 170)
      }
    }
  }

  @ViewBuilder
  private var detailPane: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Inspektor")
        .font(.headline)

      if model.isLoadingDetail {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let detail = model.selectedMessageDetail {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            detailSection("Metadata", rows: detail.metadata)

            VStack(alignment: .leading, spacing: 8) {
              Text("Obsah")
                .font(.subheadline.bold())
              if let preview = detail.plainTextPreview, !preview.isEmpty {
                Text(preview)
                  .textSelection(.enabled)
                  .font(.system(.body, design: .monospaced))
                  .frame(maxWidth: .infinity, alignment: .leading)
              } else {
                Text("Plain-text preview není bezpečně dostupný.")
                  .foregroundStyle(.secondary)
              }
            }

            attachmentSection(detail.attachments)

            if !detail.mimeWarnings.isEmpty {
              detailSection(
                "MIME upozornění",
                rows: Dictionary(
                  uniqueKeysWithValues: detail.mimeWarnings.enumerated().map {
                    ("Upozornění \($0.offset + 1)", $0.element)
                  }
                ))
            }

            detailSection(
              "Raw",
              rows: [
                "Size": ByteCountFormatter.string(
                  fromByteCount: detail.rawByteSize, countStyle: .file),
                "SHA-256": detail.rawSHA256,
              ])
            detailSection("Headers", rows: detail.headers)
          }
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        ContentUnavailableView(
          "Vyber zprávu",
          systemImage: "envelope.open",
          description: Text("Detail se načítá až po výběru řádku.")
        )
      }
    }
  }

  @ViewBuilder
  private func attachmentSection(_ attachments: [MessageAttachmentMetadata]) -> some View {
    if !attachments.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Přílohy")
          .font(.subheadline.bold())
        ForEach(attachments) { attachment in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "paperclip")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
              Text(attachment.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
              Text(
                "\(attachment.mimeType) • \(ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file))"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            }
            Spacer()
            Button {
              Task { await model.saveAttachment(attachment) }
            } label: {
              Label("Uložit přílohu", systemImage: "square.and.arrow.down")
                .labelStyle(.iconOnly)
            }
            .help("Save Attachment…")
            .buttonStyle(.bordered)
            .disabled(!model.canSaveSelectedAttachment)
          }
          .padding(8)
          .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      .textSelection(.disabled)
    }
  }

  private var footer: some View {
    HStack {
      Text(model.statusMessage)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Spustit dry run") {
        model.startRecoveryDryRun()
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.isWorking || model.selectedSourceID == nil)
    }
  }

  private var messageSelectionBinding: Binding<String?> {
    Binding(
      get: { localSelectedMessageID },
      set: { newValue in
        Task { @MainActor in
          await Task.yield()
          localSelectedMessageID = newValue
          model.selectMessage(id: newValue)
        }
      }
    )
  }

  private var messageSortBinding: Binding<[KeyPathComparator<MailMessageRecord>]> {
    Binding(
      get: { localMessageSortOrder },
      set: { newValue in
        Task { @MainActor in
          await Task.yield()
          localMessageSortOrder = newValue
          model.updateMessageSortOrder(newValue)
        }
      }
    )
  }

  private var recoverySelectionBinding: Binding<String?> {
    Binding(
      get: { localSelectedRecoveryIssueID },
      set: { newValue in
        Task { @MainActor in
          await Task.yield()
          localSelectedRecoveryIssueID = newValue
          model.selectRecoveryIssue(id: newValue)
        }
      }
    )
  }

  private var recoverySortBinding: Binding<[KeyPathComparator<RecoveryIssue>]> {
    Binding(
      get: { localRecoveryIssueSortOrder },
      set: { newValue in
        Task { @MainActor in
          await Task.yield()
          localRecoveryIssueSortOrder = newValue
          model.recoveryIssueSortOrder = newValue
        }
      }
    )
  }

  private func scheduleSearchUpdate(_ value: String) {
    searchUpdateTask?.cancel()
    searchUpdateTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      model.updateMessageSearchText(value)
    }
  }

  private func detailSection(_ title: String, rows: [String: String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.subheadline.bold())
      Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 6) {
        ForEach(rows.keys.sorted(), id: \.self) { key in
          GridRow {
            Text(key)
              .foregroundStyle(.secondary)
            Text(rows[key] ?? "")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  private func metric(_ title: String, value: String, icon: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: icon)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title.bold())
    }
    .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
    .padding()
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
  }

  private func icon(for kind: MailSourceKind) -> String {
    switch kind {
    case .imap: "network"
    case .appleMail: "apple.logo"
    case .mbox: "archivebox"
    case .eml: "doc.text"
    case .maildir: "folder"
    }
  }

  private func formatDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    return Self.dateFormatter.string(from: date)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()
}

extension String {
  fileprivate var prefixText: String {
    String(prefix(12))
  }
}
