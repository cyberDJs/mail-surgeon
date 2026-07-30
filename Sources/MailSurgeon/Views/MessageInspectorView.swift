import SwiftUI

struct MessageInspectorView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Inspektor zprávy")
        .font(.headline)
        .padding([.horizontal, .top], 14)
      Divider()
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    if model.isLoadingDetail {
      ProgressView("Načítám detail zprávy…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let detail = model.selectedMessageDetail {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          DetailSectionView(title: "Metadata", rows: detail.metadata)
          previewSection(detail)
          attachmentSection(detail.attachments)
          warningsSection(detail.mimeWarnings)
          DetailSectionView(
            title: "Raw souhrn",
            rows: [
              "Velikost": ViewFormatters.bytes(detail.rawByteSize),
              "SHA-256": detail.rawSHA256,
            ]
          )
          DetailSectionView(title: "Headers", rows: detail.headers)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      }
    } else {
      ContentUnavailableView(
        "Není vybraná zpráva",
        systemImage: "envelope.open",
        description: Text("Detail se načte až po výběru zprávy.")
      )
    }
  }

  private func previewSection(_ detail: MessageDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Preview")
        .font(.subheadline.bold())
      if let preview = detail.plainTextPreview, !preview.isEmpty {
        Text(preview)
          .font(.system(.body, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(
          "Plain-text preview není bezpečně dostupný. HTML, skripty a vzdálený obsah se nenačítají."
        )
        .foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 2) {
              Text(attachment.displayName)
                .lineLimit(1)
              Text("\(attachment.mimeType), \(ViewFormatters.bytes(attachment.byteSize))")
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
            .buttonStyle(.bordered)
            .help("Uložit přílohu")
            .disabled(!model.canSaveSelectedAttachment)
          }
          .textSelection(.disabled)
        }
      }
    }
  }

  @ViewBuilder
  private func warningsSection(_ warnings: [String]) -> some View {
    if !warnings.isEmpty {
      DetailSectionView(
        title: "MIME upozornění",
        rows: Dictionary(
          uniqueKeysWithValues: warnings.enumerated().map {
            ("Upozornění \($0.offset + 1)", $0.element)
          }
        )
      )
    }
  }
}

struct DetailSectionView: View {
  let title: String
  let rows: [String: String]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.subheadline.bold())
      ForEach(rows.keys.sorted(), id: \.self) { key in
        VStack(alignment: .leading, spacing: 2) {
          Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(rows[key] ?? "")
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
