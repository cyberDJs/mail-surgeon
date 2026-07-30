import Foundation

struct SecurityScopedBookmarkStore {
    private let defaults: UserDefaults
    private let key = "MailSurgeon.SecurityScopedBookmarks"
    private let sourceRecordsKey = "MailSurgeon.BookmarkedSources"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func saveBookmark(for url: URL, id: UUID) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = loadRawBookmarks()
        bookmarks[id.uuidString] = data
        defaults.set(bookmarks, forKey: key)
    }

    func saveSourceRecord(_ record: BookmarkedSourceRecord) {
        var records = sourceRecords().filter { $0.id != record.id }
        records.append(record)
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: sourceRecordsKey)
        }
    }

    func sourceRecords() -> [BookmarkedSourceRecord] {
        guard let data = defaults.data(forKey: sourceRecordsKey),
              let records = try? JSONDecoder().decode([BookmarkedSourceRecord].self, from: data) else {
            return []
        }
        return records
    }

    func resolveBookmark(id: UUID) throws -> BookmarkResolution? {
        var bookmarks = loadRawBookmarks()
        guard let data = bookmarks[id.uuidString] else { return nil }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            let refreshed = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarks[id.uuidString] = refreshed
            defaults.set(bookmarks, forKey: key)
        }

        return BookmarkResolution(url: url, wasStale: isStale)
    }

    private func loadRawBookmarks() -> [String: Data] {
        defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
    }
}

struct BookmarkResolution: Equatable, Sendable {
    let url: URL
    let wasStale: Bool
}

struct BookmarkedSourceRecord: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: MailSourceKind
}
