import CryptoKit
import Foundation

struct MBOXConnector: MailSourceConnector {
    let descriptor: MailSourceDescriptor

    func validateAccess() async throws {
        guard let url = descriptor.location else {
            throw ConnectorError.accessDenied("Nebyl vybrán soubor MBOX.")
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConnectorError.accessDenied("Soubor neexistuje: \(url.path)")
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConnectorError.accessDenied("Soubor nelze číst: \(url.lastPathComponent)")
        }
    }

    func folders() async throws -> [String] {
        [descriptor.location?.deletingPathExtension().lastPathComponent ?? "MBOX"]
    }

    func scanMessages() -> AsyncThrowingStream<MailMessageRecord, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    guard let url = descriptor.location else {
                        throw ConnectorError.accessDenied("Nebyl vybrán soubor MBOX.")
                    }

                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }

                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                        throw ConnectorError.malformedArchive("Soubor nelze dekódovat jako UTF-8 ani ISO Latin-1.")
                    }

                    let folder = url.deletingPathExtension().lastPathComponent
                    for (index, rawMessage) in splitMBOX(text).enumerated() {
                        if Task.isCancelled { break }
                        guard !rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                        let rawData = Data(rawMessage.utf8)
                        let headers = parseHeaders(from: rawMessage)
                        let record = MailMessageRecord(
                            sourceIdentifier: "\(url.path)#\(index + 1)",
                            folderPath: folder,
                            messageID: header("Message-ID", in: headers),
                            subject: decodeHeader(header("Subject", in: headers) ?? "(bez předmětu)"),
                            sender: decodeHeader(header("From", in: headers) ?? ""),
                            recipients: parseRecipients(header("To", in: headers)),
                            sentDate: parseDate(header("Date", in: headers)),
                            byteSize: Int64(rawData.count),
                            rawSHA256: SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined(),
                            hasAttachments: hasAttachment(headers: headers, rawMessage: rawMessage),
                            headers: headers
                        )
                        continuation.yield(record)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func splitMBOX(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var messages: [String] = []
        var current: [Substring] = []

        for line in lines {
            if line.hasPrefix("From ") {
                if !current.isEmpty {
                    messages.append(current.joined(separator: "\n"))
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            current.append(line)
        }

        if !current.isEmpty {
            messages.append(current.joined(separator: "\n"))
        }
        return messages
    }

    private func parseHeaders(from rawMessage: String) -> [String: String] {
        let normalized = rawMessage.replacingOccurrences(of: "\r\n", with: "\n")
        guard let separator = normalized.range(of: "\n\n") else { return [:] }
        let headerBlock = normalized[..<separator.lowerBound]

        var headers: [String: String] = [:]
        var currentName: String?

        for line in headerBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                if let currentName {
                    headers[currentName, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
            currentName = name
        }
        return headers
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func parseRecipients(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func hasAttachment(headers: [String: String], rawMessage: String) -> Bool {
        let disposition = header("Content-Disposition", in: headers) ?? ""
        if disposition.localizedCaseInsensitiveContains("attachment") { return true }
        return rawMessage.localizedCaseInsensitiveContains("Content-Disposition: attachment")
            || rawMessage.localizedCaseInsensitiveContains("filename=")
    }

    private func decodeHeader(_ value: String) -> String {
        // RFC 2047 decoding will be added in the next parser pass. Preserve the original value for now.
        value
    }
}
