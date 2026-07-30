import CryptoKit
import Foundation

struct MailMessageParser: Sendable {
    private let headerDecoder = RFC2047Decoder()

    func record(
        from rawData: Data,
        fileURL: URL,
        root: URL,
        folder: String,
        byteOffset: UInt64
    ) -> MailMessageRecord {
        let rawMessage = decodeMessage(rawData)
        let headers = parseHeaders(from: rawMessage)
        let subject = header("Subject", in: headers).map(headerDecoder.decode) ?? "(bez předmětu)"
        let sender = header("From", in: headers).map(headerDecoder.decode) ?? ""
        let recipients = parseRecipients(header("To", in: headers))
        let hash = sha256(rawData)
        let byteLength = Int64(rawData.count)

        return MailMessageRecord(
            sourceIdentifier: "\(fileURL.path)#\(byteOffset):\(byteLength)",
            folderPath: folder,
            messageID: header("Message-ID", in: headers),
            subject: subject,
            sender: sender,
            recipients: recipients,
            sentDate: parseDate(header("Date", in: headers)),
            byteSize: byteLength,
            rawSHA256: hash,
            hasAttachments: hasAttachment(headers: headers, rawMessage: rawMessage),
            headers: headers,
            location: MessageStorageLocation(
                fileURL: fileURL,
                byteOffset: byteOffset,
                byteLength: byteLength
            ),
            classificationFlags: classify(
                subject: subject,
                headers: headers,
                byteSize: byteLength
            )
        )
    }

    func detail(from rawData: Data, sourceIdentifier: String) -> MessageDetail {
        let rawMessage = decodeMessage(rawData)
        let headers = parseHeaders(from: rawMessage)
        return MessageDetail(
            sourceIdentifier: sourceIdentifier,
            headers: headers,
            metadata: [
                "Message-ID": header("Message-ID", in: headers) ?? "",
                "Subject": header("Subject", in: headers).map(headerDecoder.decode) ?? "",
                "From": header("From", in: headers).map(headerDecoder.decode) ?? "",
                "To": header("To", in: headers).map(headerDecoder.decode) ?? "",
                "Date": header("Date", in: headers) ?? ""
            ],
            plainTextPreview: plainTextPreview(from: rawMessage, headers: headers),
            rawByteSize: Int64(rawData.count),
            rawSHA256: sha256(rawData)
        )
    }

    func parseHeaders(from rawMessage: String) -> [String: String] {
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

    func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func classify(subject: String, headers: [String: String], byteSize: Int64) -> MessageClassificationFlags {
        var flags: MessageClassificationFlags = []

        if headers.keys.contains(where: { $0.caseInsensitiveCompare("List-Unsubscribe") == .orderedSame })
            || headers.keys.contains(where: { $0.caseInsensitiveCompare("List-ID") == .orderedSame }) {
            flags.insert(.newsletter)
        }

        let otpTerms = ["verification code", "one-time password", "otp", "ověřovací kód"]
        if otpTerms.contains(where: { subject.localizedCaseInsensitiveContains($0) }) {
            flags.insert(.oneTimeCode)
        }

        if byteSize >= 25 * 1_024 * 1_024 {
            flags.insert(.large)
        }

        let sensitiveTerms = ["invoice", "faktura", "smlouva", "contract", "bank", "úřad"]
        if sensitiveTerms.contains(where: { subject.localizedCaseInsensitiveContains($0) }) {
            flags.insert(.sensitive)
        }

        return flags
    }

    func decodeMessage(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private func parseRecipients(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").map {
            headerDecoder.decode($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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

    private func plainTextPreview(from rawMessage: String, headers: [String: String]) -> String? {
        let contentType = header("Content-Type", in: headers) ?? "text/plain"
        guard !contentType.localizedCaseInsensitiveContains("text/html") else {
            return nil
        }

        let normalized = rawMessage.replacingOccurrences(of: "\r\n", with: "\n")
        guard let separator = normalized.range(of: "\n\n") else { return nil }
        let body = String(normalized[separator.upperBound...])
        guard !body.localizedCaseInsensitiveContains("<html"),
              !body.localizedCaseInsensitiveContains("<body") else {
            return nil
        }
        return String(body.prefix(8_000))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
