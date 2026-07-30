import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

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
                analysisGrid
                browserWorkspace
                footer
            }
            .padding(24)
            .onChange(of: model.selectedSourceID) { _, _ in
                model.messages = []
                model.selectedMessageID = nil
                model.selectedMessageDetail = nil
            }
            .onChange(of: model.selectedMessageID) { _, _ in
                Task { await model.loadSelectedMessageDetail() }
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
                Label(ByteCountFormatter.string(fromByteCount: model.progress.bytesScanned, countStyle: .file), systemImage: "doc.text.magnifyingglass")
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

    private var analysisGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 18) {
            GridRow {
                metric("Zprávy", value: "\(model.analysis.totalMessages)", icon: "envelope")
                metric("Velikost", value: ByteCountFormatter.string(fromByteCount: model.analysis.totalBytes, countStyle: .file), icon: "externaldrive")
                metric("Duplicity", value: "\(model.analysis.exactDuplicates)", icon: "doc.on.doc")
            }
            GridRow {
                metric("Newslettery", value: "\(model.analysis.likelyNewsletters)", icon: "megaphone")
                metric("OTP", value: "\(model.analysis.likelyOneTimeCodes)", icon: "number.square")
                metric("Citlivé", value: "\(model.analysis.sensitiveCandidates)", icon: "lock.shield")
            }
            GridRow {
                metric("Velké zprávy", value: "\(model.analysis.largeMessages)", icon: "tray.full")
                Color.clear
                Color.clear
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
            TextField("Hledat", text: $model.messageSearchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)

            ForEach(MessageFilter.allCases) { filter in
                Toggle(filter.rawValue, isOn: Binding(
                    get: { model.enabledMessageFilters.contains(filter) },
                    set: { model.setFilter(filter, enabled: $0) }
                ))
                .toggleStyle(.checkbox)
            }

            Spacer()

            Button {
                Task { await model.loadMessagesForSelectedSource() }
            } label: {
                Label("Načíst zprávy", systemImage: "tray.and.arrow.down")
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
            Table(model.displayedMessages, selection: $model.selectedMessageID, sortOrder: $model.tableSortOrder) {
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
                    Text(ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file))
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

                        detailSection("Raw", rows: [
                            "Size": ByteCountFormatter.string(fromByteCount: detail.rawByteSize, countStyle: .file),
                            "SHA-256": detail.rawSHA256
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

    private var footer: some View {
        HStack {
            Text(model.statusMessage)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Spustit dry run") {
                Task { await model.runDryAnalysis() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || model.selectedSourceID == nil)
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
