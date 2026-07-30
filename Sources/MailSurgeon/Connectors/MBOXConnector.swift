import CryptoKit
import Foundation

struct MBOXConnector: MailSourceConnector {
    let descriptor: MailSourceDescriptor

    func validateAccess() async throws {
        guard let url = descriptor.location else {
            throw ConnectorError.accessDenied("Nebyl vybrán soubor MBOX.")
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConnectorError.missingFile(url.path)
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConnectorError.unreadableFile(url.lastPathComponent)
        }

        _ = try mboxFiles(in: url)
    }

    func folders() async throws -> [String] {
        guard let url = descriptor.location else { return ["MBOX"] }
        let files = try mboxFiles(in: url)
        return files.map { folderName(for: $0, root: url) }
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

                    let files = try mboxFiles(in: url)
                    var emittedMessages = 0
                    for fileURL in files {
                        try Task.checkCancellation()
                        emittedMessages += try scanFile(
                            fileURL,
                            root: url,
                            startingAt: emittedMessages,
                            continuation: continuation
                        )
                    }

                    guard emittedMessages > 0 else {
                        throw ConnectorError.emptyArchive(url.lastPathComponent)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func mboxFiles(in url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ConnectorError.missingFile(url.path)
        }

        if !isDirectory.boolValue {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw ConnectorError.unreadableFile(url.lastPathComponent)
            }
            return [url]
        }

        let bundleFile = url.appendingPathComponent("mbox")
        if FileManager.default.fileExists(atPath: bundleFile.path),
           FileManager.default.isReadableFile(atPath: bundleFile.path) {
            return [bundleFile]
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ConnectorError.unreadableFile(url.lastPathComponent)
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values.isRegularFile == true,
                  values.isReadable == true else { continue }

            if fileURL.lastPathComponent == "mbox" || fileURL.pathExtension.lowercased() == "mbox" {
                files.append(fileURL)
            }
        }

        guard !files.isEmpty else {
            throw ConnectorError.malformedArchive("Ve vybrané složce nebyl nalezen čitelný MBOX soubor.")
        }

        return files.sorted { $0.path < $1.path }
    }

    private func scanFile(
        _ fileURL: URL,
        root: URL,
        startingAt startingIndex: Int,
        continuation: AsyncThrowingStream<MailMessageRecord, Error>.Continuation
    ) throws -> Int {
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw ConnectorError.unreadableFile(fileURL.lastPathComponent)
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var pending = Data()
        var currentMessage = Data()
        var emittedMessages = 0
        var sawDelimiter = false
        var sawNonEmptyBeforeDelimiter = false
        let newline = Data([0x0A])

        func consume(_ line: Data) throws {
            try Task.checkCancellation()

            if isMBOXDelimiter(line) {
                sawDelimiter = true
                if !currentMessage.isEmpty {
                    emittedMessages += 1
                    continuation.yield(record(
                        from: currentMessage,
                        fileURL: fileURL,
                        root: root,
                        index: startingIndex + emittedMessages
                    ))
                    currentMessage.removeAll(keepingCapacity: true)
                }
                return
            }

            if !sawDelimiter && !line.trimmingASCIIWhitespace().isEmpty {
                sawNonEmptyBeforeDelimiter = true
            }

            if sawDelimiter {
                currentMessage.append(line)
            }
        }

        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            pending.append(chunk)
            while let range = pending.firstRange(of: newline) {
                let line = pending[..<range.upperBound]
                try consume(Data(line))
                pending.removeSubrange(..<range.upperBound)
            }
        }

        if !pending.isEmpty {
            try consume(pending)
        }

        if !currentMessage.isEmpty {
            emittedMessages += 1
            continuation.yield(record(
                from: currentMessage,
                fileURL: fileURL,
                root: root,
                index: startingIndex + emittedMessages
            ))
        }

        if !sawDelimiter && sawNonEmptyBeforeDelimiter {
            throw ConnectorError.malformedArchive("\(fileURL.lastPathComponent) nezačíná MBOX oddělovačem „From “.")
        }

        return emittedMessages
    }

    private func isMBOXDelimiter(_ line: Data) -> Bool {
        let prefix = Data("From ".utf8)
        return line.starts(with: prefix)
    }

    private func record(from rawData: Data, fileURL: URL, root: URL, index: Int) -> MailMessageRecord {
        let rawMessage = decodeMessage(rawData)
        let headers = parseHeaders(from: rawMessage)
        return MailMessageRecord(
            sourceIdentifier: "\(fileURL.path)#\(index)",
            folderPath: folderName(for: fileURL, root: root),
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
    }

    private func folderName(for fileURL: URL, root: URL) -> String {
        if fileURL.lastPathComponent == "mbox" {
            return fileURL.deletingLastPathComponent().deletingPathExtension().lastPathComponent
        }
        if fileURL == root {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    private func decodeMessage(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
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

private extension Data {
    func trimmingASCIIWhitespace() -> Data {
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        var start = startIndex
        var end = endIndex

        while start < end, whitespace.contains(self[start]) {
            start = index(after: start)
        }

        while end > start {
            let previous = index(before: end)
            guard whitespace.contains(self[previous]) else { break }
            end = previous
        }

        return self[start..<end]
    }
}
