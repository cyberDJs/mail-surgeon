import Foundation

struct MIMEParser: Sendable {
    private let headerDecoder = RFC2047Decoder()

    func parse(_ data: Data) -> MIMEMessage {
        var warnings: [String] = []
        let root = parseEntity(data, path: "1", warnings: &warnings)
        return MIMEMessage(
            root: root,
            safePlainTextPreview: safePreview(from: root),
            attachments: attachments(in: root),
            warnings: warnings
        )
    }

    func decodedAttachmentData(id: String, from data: Data) -> Data? {
        parse(data).attachments.first { $0.metadata.id == id }?.decodedData
    }

    private func parseEntity(_ data: Data, path: String, warnings: inout [String]) -> MIMEPart {
        let split = splitHeaderAndBody(data)
        let headers = MIMEHeaders(data: split.headers, decoder: headerDecoder)
        let contentType = headers.contentType
        let disposition = headers.contentDisposition
        let transferEncoding =
            headers.value(for: "Content-Transfer-Encoding")?.lowercased() ?? "7bit"
        let contentID = headers.value(for: "Content-ID").map(trimAngleBrackets)

        if contentType.mediaType.hasPrefix("multipart/") {
            guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty else {
                warnings.append("Multipart part \(path) is missing a boundary.")
                return MIMEPart(
                    id: path,
                    headers: headers.dictionary,
                    mediaType: contentType.mediaType,
                    parameters: contentType.parameters,
                    disposition: disposition.disposition,
                    dispositionParameters: disposition.parameters,
                    transferEncoding: transferEncoding,
                    contentID: contentID,
                    decodedBody: nil,
                    children: [],
                    warnings: warnings
                )
            }

            let rawChildren = splitMultipartBody(
                split.body, boundary: boundary, path: path, warnings: &warnings)
            let children = rawChildren.enumerated().map { index, childData in
                parseEntity(childData, path: "\(path).\(index + 1)", warnings: &warnings)
            }

            return MIMEPart(
                id: path,
                headers: headers.dictionary,
                mediaType: contentType.mediaType,
                parameters: contentType.parameters,
                disposition: disposition.disposition,
                dispositionParameters: disposition.parameters,
                transferEncoding: transferEncoding,
                contentID: contentID,
                decodedBody: nil,
                children: children,
                warnings: warnings
            )
        }

        if contentType.mediaType == "message/rfc822" {
            let decoded = decodeTransfer(
                split.body, encoding: transferEncoding, path: path, warnings: &warnings)
            let child = parseEntity(decoded, path: "\(path).1", warnings: &warnings)
            return MIMEPart(
                id: path,
                headers: headers.dictionary,
                mediaType: contentType.mediaType,
                parameters: contentType.parameters,
                disposition: disposition.disposition,
                dispositionParameters: disposition.parameters,
                transferEncoding: transferEncoding,
                contentID: contentID,
                decodedBody: decoded,
                children: [child],
                warnings: warnings
            )
        }

        let decoded = decodeTransfer(
            split.body, encoding: transferEncoding, path: path, warnings: &warnings)
        return MIMEPart(
            id: path,
            headers: headers.dictionary,
            mediaType: contentType.mediaType,
            parameters: contentType.parameters,
            disposition: disposition.disposition,
            dispositionParameters: disposition.parameters,
            transferEncoding: transferEncoding,
            contentID: contentID,
            decodedBody: decoded,
            children: [],
            warnings: warnings
        )
    }

    private func splitHeaderAndBody(_ data: Data) -> (headers: Data, body: Data) {
        let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lf = Data([0x0A, 0x0A])

        if let range = data.firstRange(of: crlf) {
            return (Data(data[..<range.lowerBound]), Data(data[range.upperBound...]))
        }
        if let range = data.firstRange(of: lf) {
            return (Data(data[..<range.lowerBound]), Data(data[range.upperBound...]))
        }
        return (data, Data())
    }

    private func splitMultipartBody(
        _ body: Data,
        boundary: String,
        path: String,
        warnings: inout [String]
    ) -> [Data] {
        let marker = Data("--\(boundary)".utf8)
        let closingMarker = Data("--\(boundary)--".utf8)
        var parts: [Data] = []
        var current = Data()
        var insidePart = false
        var sawClosingBoundary = false
        var cursor = body.startIndex

        while cursor < body.endIndex {
            let lineEnd =
                body[cursor...].firstIndex(of: 0x0A).map { body.index(after: $0) } ?? body.endIndex
            let rawLine = body[cursor..<lineEnd]
            let line = rawLine.trimmingLineEnding()
            if line == marker || line == closingMarker {
                if insidePart {
                    parts.append(current.trimmingTrailingLineEnding())
                    current.removeAll(keepingCapacity: true)
                }
                insidePart = line.elementsEqual(marker)
                sawClosingBoundary = line.elementsEqual(closingMarker)
                cursor = lineEnd
                continue
            }

            if insidePart {
                current.append(contentsOf: rawLine)
            }
            cursor = lineEnd
        }

        if insidePart {
            if !current.isEmpty {
                parts.append(current.trimmingTrailingLineEnding())
            }
            warnings.append("Multipart part \(path) is missing a closing boundary.")
        } else if !sawClosingBoundary {
            warnings.append("Multipart part \(path) has no matching boundary parts.")
        }

        return parts
    }

    private func decodeTransfer(
        _ data: Data, encoding: String, path: String, warnings: inout [String]
    ) -> Data {
        switch encoding.lowercased() {
        case "base64":
            let compact = compactBase64(data)
            let hasInvalidBytes = data.contains {
                !isBase64Byte($0) && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0x20
            }
            if !hasInvalidBytes, let decoded = Data(base64Encoded: compact) {
                return decoded
            }
            warnings.append("Part \(path) has invalid Base64 content.")
            return decodeLenientBase64Prefix(data)
        case "quoted-printable":
            return decodeQuotedPrintable(data, path: path, warnings: &warnings)
        case "7bit", "8bit", "binary":
            return data
        default:
            warnings.append("Part \(path) has unsupported transfer encoding \(encoding).")
            return data
        }
    }

    private func compactBase64(_ data: Data) -> Data {
        data.filter { byte in
            isBase64Byte(byte) || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
        }
        .filter { byte in
            byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x20
        }
    }

    private func decodeLenientBase64Prefix(_ data: Data) -> Data {
        var prefix = Data()
        for byte in data {
            if byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20 {
                continue
            }
            guard isBase64Byte(byte) else { break }
            prefix.append(byte)
        }
        return decodeLenientBase64(prefix)
    }

    private func decodeLenientBase64(_ data: Data) -> Data {
        var output = Data()
        var quartet: [UInt8] = []

        for byte in data where byte != 0x3D {
            quartet.append(byte)
            if quartet.count == 4 {
                if let decoded = Data(base64Encoded: Data(quartet)) {
                    output.append(decoded)
                }
                quartet.removeAll(keepingCapacity: true)
            }
        }

        if quartet.count >= 2 {
            while quartet.count < 4 {
                quartet.append(0x3D)
            }
            if let decoded = Data(base64Encoded: Data(quartet)) {
                output.append(decoded)
            }
        }

        return output
    }

    private func isBase64Byte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x2B
            || byte == 0x2F
            || byte == 0x3D
    }

    private func decodeQuotedPrintable(_ data: Data, path: String, warnings: inout [String]) -> Data
    {
        var output = Data()
        let bytes = Array(data)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                    let high = hexValue(bytes[index + 1]),
                    let low = hexValue(bytes[index + 2])
                {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                warnings.append("Part \(path) has malformed quoted-printable content.")
            }

            output.append(byte)
            index += 1
        }

        return output
    }

    private func safePreview(from root: MIMEPart) -> String? {
        if root.mediaType == "multipart/alternative" {
            return preferredAlternativePreview(in: root)
        }

        if let directText = textPreview(from: root) {
            return directText
        }

        for child in root.children {
            if let preview = child.mediaType == "multipart/alternative"
                ? preferredAlternativePreview(in: child)
                : safePreview(from: child)
            {
                return preview
            }
        }
        return nil
    }

    private func preferredAlternativePreview(in part: MIMEPart) -> String? {
        if let plain = part.children.lazy.compactMap({ textPreview(from: $0, onlyPlain: true) })
            .first
        {
            return plain
        }
        return part.children.lazy.compactMap { textPreview(from: $0, onlyHTML: true) }.first
    }

    private func textPreview(from part: MIMEPart, onlyPlain: Bool = false, onlyHTML: Bool = false)
        -> String?
    {
        guard !isAttachment(part), let decodedBody = part.decodedBody else { return nil }

        if !onlyHTML, part.mediaType == "text/plain" {
            return decodeText(decodedBody, charset: part.parameters["charset"]).map(limitPreview)
        }

        if !onlyPlain, part.mediaType == "text/html",
            let html = decodeText(decodedBody, charset: part.parameters["charset"])
        {
            return limitPreview(extractSafeTextFromHTML(html))
        }

        return nil
    }

    private func decodeText(_ data: Data, charset: String?) -> String? {
        let normalizedCharset = charset?.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines)
        let encodings: [String.Encoding]
        switch normalizedCharset {
        case "utf-8", "utf8":
            encodings = [.utf8, .isoLatin1]
        case "us-ascii", "ascii":
            encodings = [.ascii, .utf8, .isoLatin1]
        case "iso-8859-1", "latin1", "latin-1":
            encodings = [.isoLatin1, .utf8]
        case "windows-1250", "cp1250":
            encodings = [Self.windows1250Encoding, .utf8, .isoLatin1]
        case "windows-1252", "cp1252":
            encodings = [Self.windows1252Encoding, .utf8, .isoLatin1]
        default:
            encodings = [.utf8, .ascii, .isoLatin1]
        }

        for encoding in encodings {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }
        return nil
    }

    private func extractSafeTextFromHTML(_ html: String) -> String {
        var text = html
        text = replace(pattern: #"(?is)<(script|style)[^>]*>.*?</\1>"#, in: text, with: " ")
        text = replace(pattern: #"(?is)<!--.*?-->"#, in: text, with: " ")
        text = replace(pattern: #"(?is)<(br|p|div|tr|li|h[1-6])\b[^>]*>"#, in: text, with: "\n")
        text = replace(pattern: #"(?is)<[^>]+>"#, in: text, with: " ")
        text = decodeHTMLEntities(text)
        return normalizePreviewWhitespace(text)
    }

    private func replace(pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        var result =
            value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let nsValue = result as NSString
            var updated = ""
            var cursor = 0
            for match in regex.matches(
                in: result, range: NSRange(location: 0, length: nsValue.length))
            {
                updated += nsValue.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor))
                let number = nsValue.substring(with: match.range(at: 1))
                if let scalarValue = UInt32(number), let scalar = UnicodeScalar(scalarValue) {
                    updated += String(Character(scalar))
                } else {
                    updated += nsValue.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
            }
            updated += nsValue.substring(from: cursor)
            result = updated
        }

        return result
    }

    private func attachments(in part: MIMEPart) -> [MIMEAttachment] {
        var result: [MIMEAttachment] = []
        collectAttachments(in: part, into: &result)
        return result
    }

    private func collectAttachments(in part: MIMEPart, into result: inout [MIMEAttachment]) {
        if isAttachment(part), let decodedBody = part.decodedBody {
            let filename =
                part.dispositionParameters["filename"]
                ?? part.parameters["name"]
            result.append(
                MIMEAttachment(
                    metadata: MessageAttachmentMetadata(
                        id: part.id,
                        filename: filename.map(headerDecoder.decode),
                        mimeType: part.mediaType,
                        byteSize: Int64(decodedBody.count),
                        contentID: part.contentID,
                        disposition: part.disposition,
                        transferEncoding: part.transferEncoding,
                        lazyReference: part.id
                    ),
                    decodedData: decodedBody
                ))
        }

        for child in part.children {
            collectAttachments(in: child, into: &result)
        }
    }

    private func isAttachment(_ part: MIMEPart) -> Bool {
        if part.disposition?.caseInsensitiveCompare("attachment") == .orderedSame { return true }
        if part.disposition?.caseInsensitiveCompare("inline") == .orderedSame {
            return part.dispositionParameters["filename"] != nil || part.parameters["name"] != nil
        }
        return part.parameters["name"] != nil
            || part.dispositionParameters["filename"] != nil
            || (part.mediaType == "application/octet-stream" && part.decodedBody != nil)
    }

    private func limitPreview(_ value: String) -> String {
        String(normalizePreviewWhitespace(value).prefix(8_000))
    }

    private func normalizePreviewWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.split(separator: " ").joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimAngleBrackets(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            byte - 48
        case 65...70:
            byte - 55
        case 97...102:
            byte - 87
        default:
            nil
        }
    }

    private static let windows1250Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsLatin2.rawValue)
        ))
    private static let windows1252Encoding = String.Encoding(rawValue: 12)
}

struct MIMEMessage: Equatable, Sendable {
    let root: MIMEPart
    let safePlainTextPreview: String?
    let attachments: [MIMEAttachment]
    let warnings: [String]
}

struct MIMEPart: Equatable, Sendable {
    let id: String
    let headers: [String: String]
    let mediaType: String
    let parameters: [String: String]
    let disposition: String?
    let dispositionParameters: [String: String]
    let transferEncoding: String
    let contentID: String?
    let decodedBody: Data?
    let children: [MIMEPart]
    let warnings: [String]
}

struct MIMEAttachment: Equatable, Sendable {
    let metadata: MessageAttachmentMetadata
    let decodedData: Data
}

private struct MIMEHeaders {
    let fields: [(name: String, value: String)]
    let dictionary: [String: String]
    let contentType: MIMEParameterizedHeader
    let contentDisposition: MIMEParameterizedHeader

    init(data: Data, decoder: RFC2047Decoder) {
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        var fields: [(name: String, value: String)] = []
        var currentName: String?
        var currentValue = ""

        func flush() {
            guard let currentName else { return }
            fields.append(
                (currentName, currentValue.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else {
                currentName = nil
                currentValue = ""
                continue
            }
            currentName = String(line[..<colon])
            currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(
                in: .whitespaces)
        }
        flush()

        self.fields = fields
        var dictionary: [String: String] = [:]
        for field in fields {
            if let existingKey = dictionary.keys.first(where: {
                $0.caseInsensitiveCompare(field.name) == .orderedSame
            }) {
                dictionary[existingKey, default: ""] += ", \(field.value)"
            } else {
                dictionary[field.name] = field.value
            }
        }
        self.dictionary = dictionary
        self.contentType = MIMEParameterizedHeader(
            rawValue: Self.value("Content-Type", in: fields) ?? "text/plain; charset=us-ascii",
            defaultValue: "text/plain",
            decoder: decoder
        )
        self.contentDisposition = MIMEParameterizedHeader(
            rawValue: Self.value("Content-Disposition", in: fields) ?? "",
            defaultValue: "",
            decoder: decoder
        )
    }

    func value(for name: String) -> String? {
        Self.value(name, in: fields)
    }

    private static func value(_ name: String, in fields: [(name: String, value: String)]) -> String?
    {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private struct MIMEParameterizedHeader {
    let value: String
    let parameters: [String: String]

    var mediaType: String {
        value.lowercased()
    }

    var disposition: String? {
        value.isEmpty ? nil : value.lowercased()
    }

    init(rawValue: String, defaultValue: String, decoder: RFC2047Decoder) {
        let segments = Self.splitParameters(rawValue)
        let base = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = (base?.isEmpty == false ? base : defaultValue)?.lowercased() ?? defaultValue
        self.parameters = Self.parameters(from: Array(segments.dropFirst()), decoder: decoder)
    }

    private static func parameters(from segments: [String], decoder: RFC2047Decoder) -> [String:
        String]
    {
        var simple: [String: String] = [:]
        var encodedSingles: [String: String] = [:]
        var continuations: [String: [Int: (encoded: Bool, value: String)]] = [:]

        for segment in segments {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let rawName = String(segment[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = String(segment[segment.index(after: equals)...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let value = unquote(rawValue)

            if rawName.hasSuffix("*"), !rawName.dropLast().contains("*") {
                encodedSingles[String(rawName.dropLast())] = decodeRFC2231Value(value) ?? value
                continue
            }

            if let star = rawName.firstIndex(of: "*") {
                let base = String(rawName[..<star])
                let suffix = String(rawName[rawName.index(after: star)...])
                let encoded = suffix.hasSuffix("*")
                let indexText = encoded ? String(suffix.dropLast()) : suffix
                if let index = Int(indexText) {
                    continuations[base, default: [:]][index] = (encoded, value)
                }
                continue
            }

            simple[rawName] = decoder.decode(value)
        }

        for (key, value) in encodedSingles {
            simple[key] = decoder.decode(value)
        }

        for (key, pieces) in continuations {
            let joined = pieces.keys.sorted().compactMap { pieces[$0]?.value }.joined()
            if pieces.values.contains(where: \.encoded), let decoded = decodeRFC2231Value(joined) {
                simple[key] = decoder.decode(decoded)
            } else {
                simple[key] = decoder.decode(joined)
            }
        }

        return simple
    }

    private static func splitParameters(_ rawValue: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for character in rawValue {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                current.append(character)
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if character == ";", !inQuotes {
                result.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        result.append(current)
        return result
    }

    private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        var inner = String(value.dropFirst().dropLast())
        inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
        inner = inner.replacingOccurrences(of: "\\\\", with: "\\")
        return inner
    }

    private static func decodeRFC2231Value(_ value: String) -> String? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let encodedText = parts.count == 3 ? String(parts[2]) : value
        var bytes: [UInt8] = []
        let rawBytes = Array(encodedText.utf8)
        var index = 0

        while index < rawBytes.count {
            if rawBytes[index] == 0x25,
                index + 2 < rawBytes.count,
                let high = hexValue(rawBytes[index + 1]),
                let low = hexValue(rawBytes[index + 2])
            {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(rawBytes[index])
                index += 1
            }
        }

        return String(data: Data(bytes), encoding: .utf8)
            ?? String(data: Data(bytes), encoding: .isoLatin1)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            byte - 48
        case 65...70:
            byte - 55
        case 97...102:
            byte - 87
        default:
            nil
        }
    }
}

extension Data.SubSequence {
    fileprivate func trimmingLineEnding() -> Data {
        var end = endIndex
        if end > startIndex {
            let previous = index(before: end)
            if self[previous] == 0x0A {
                end = previous
            }
        }
        if end > startIndex {
            let previous = index(before: end)
            if self[previous] == 0x0D {
                end = previous
            }
        }
        return Data(self[startIndex..<end])
    }
}

extension Data {
    fileprivate func trimmingTrailingLineEnding() -> Data {
        var end = endIndex
        if end > startIndex {
            let previous = index(before: end)
            if self[previous] == 0x0A {
                end = previous
            }
        }
        if end > startIndex {
            let previous = index(before: end)
            if self[previous] == 0x0D {
                end = previous
            }
        }
        return Data(self[startIndex..<end])
    }
}
