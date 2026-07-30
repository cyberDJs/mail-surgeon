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
            VStack(alignment: .leading, spacing: 20) {
                header
                progressSummary
                analysisGrid
                Spacer()
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
            .padding(24)
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
}
