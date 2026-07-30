import Foundation

struct MessageBrowser: Sendable {
    private let factory = ConnectorFactory()
    private let parser = MailMessageParser()

    func loadSummaries(
        source: MailSourceDescriptor,
        progress: (@MainActor @Sendable (AnalysisProgress) -> Void)? = nil
    ) async throws -> [MailMessageRecord] {
        let connector = factory.makeConnector(for: source)
        try await connector.validateAccess()

        var records: [MailMessageRecord] = []
        var bytesScanned: Int64 = 0

        for try await record in connector.scanMessages() {
            records.append(record)
            bytesScanned += record.byteSize
            await progress?(AnalysisProgress(
                messagesScanned: records.count,
                bytesScanned: bytesScanned,
                status: "Načítám přehled: \(record.folderPath)"
            ))
        }

        return markDuplicates(in: records)
    }

    func loadDetail(for record: MailMessageRecord) async throws -> MessageDetail {
        guard let location = record.location else {
            throw ConnectorError.accessDenied("Zpráva nemá uložené umístění pro on-demand čtení.")
        }

        return try await Task.detached {
            let scoped = location.fileURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { location.fileURL.stopAccessingSecurityScopedResource() }
            }

            let handle = try FileHandle(forReadingFrom: location.fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: location.byteOffset)
            guard let data = try handle.read(upToCount: Int(location.byteLength)) else {
                throw ConnectorError.unreadableFile(location.fileURL.lastPathComponent)
            }
            return parser.detail(from: data, sourceIdentifier: record.sourceIdentifier)
        }.value
    }

    func filter(
        records: [MailMessageRecord],
        searchText: String,
        enabledFilters: Set<MessageFilter>
    ) -> [MailMessageRecord] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            let matchesSearch: Bool
            if trimmedSearch.isEmpty {
                matchesSearch = true
            } else {
                matchesSearch = record.subject.localizedCaseInsensitiveContains(trimmedSearch)
                    || record.sender.localizedCaseInsensitiveContains(trimmedSearch)
                    || record.recipients.contains { $0.localizedCaseInsensitiveContains(trimmedSearch) }
            }

            guard matchesSearch else { return false }
            guard !enabledFilters.isEmpty else { return true }
            return enabledFilters.contains { record.classificationFlags.contains($0.flag) }
        }
    }

    func sort(
        records: [MailMessageRecord],
        descriptor: MessageSortDescriptor
    ) -> [MailMessageRecord] {
        records.sorted { lhs, rhs in
            let result: ComparisonResult
            switch descriptor.column {
            case .date:
                result = compare(lhs.sentDate, rhs.sentDate)
            case .sender:
                result = lhs.sender.localizedCaseInsensitiveCompare(rhs.sender)
            case .subject:
                result = lhs.subject.localizedCaseInsensitiveCompare(rhs.subject)
            case .size:
                result = compare(lhs.byteSize, rhs.byteSize)
            case .attachment:
                result = compare(lhs.attachmentSortKey, rhs.attachmentSortKey)
            case .category:
                result = lhs.classificationFlags.displayLabel.localizedCaseInsensitiveCompare(
                    rhs.classificationFlags.displayLabel
                )
            }

            if result == .orderedSame {
                return lhs.sourceIdentifier < rhs.sourceIdentifier
            }
            return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func markDuplicates(in records: [MailMessageRecord]) -> [MailMessageRecord] {
        let counts = Dictionary(grouping: records, by: \.rawSHA256).mapValues(\.count)
        return records.map { record in
            var updated = record
            if counts[record.rawSHA256, default: 0] > 1 {
                updated.classificationFlags.insert(.duplicate)
            }
            return updated
        }
    }

    private func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case (.none, .some):
            return .orderedAscending
        case (.some, .none):
            return .orderedDescending
        case (.none, .none):
            return .orderedSame
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}
