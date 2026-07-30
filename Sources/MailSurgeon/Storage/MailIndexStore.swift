import Foundation
import SQLite3

enum MailIndexError: LocalizedError {
  case openFailed(String)
  case sqlite(String)
  case missingSourceLocation
  case unsafeDeletePath(URL)

  var errorDescription: String? {
    switch self {
    case .openFailed(let detail): "Index databázi nelze otevřít: \(detail)"
    case .sqlite(let detail): "SQLite chyba: \(detail)"
    case .missingSourceLocation: "Zdroj nemá uloženou cestu."
    case .unsafeDeletePath(let url): "Index nelze smazat mimo Mail Surgeon složku: \(url.path)"
    }
  }
}

final class MailIndexStore: @unchecked Sendable {
  static let currentSchemaVersion = 2

  private let databaseURL: URL
  private var db: OpaquePointer?

  init(databaseURL: URL) throws {
    self.databaseURL = databaseURL
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    guard
      sqlite3_open_v2(
        databaseURL.path,
        &db,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
      ) == SQLITE_OK
    else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      throw MailIndexError.openFailed(message)
    }

    try execute("PRAGMA foreign_keys = ON")
    try execute("PRAGMA journal_mode = WAL")
    try execute("PRAGMA synchronous = NORMAL")
    try migrateIfNeeded()
  }

  deinit {
    if let db {
      sqlite3_close(db)
    }
  }

  static func applicationSupportDirectory() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root.appendingPathComponent("MailSurgeon", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func defaultDatabaseURL() throws -> URL {
    try applicationSupportDirectory().appendingPathComponent("MailSurgeon.sqlite")
  }

  static func deleteDatabase(at databaseURL: URL) throws {
    let support = try applicationSupportDirectory().standardizedFileURL.path
    let target = databaseURL.standardizedFileURL.path
    guard target.hasPrefix(support + "/") else {
      throw MailIndexError.unsafeDeletePath(databaseURL)
    }
    let sidecars = ["", "-wal", "-shm"]
    for suffix in sidecars {
      let url = URL(fileURLWithPath: target + suffix)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  var sizeOnDisk: Int64 {
    let sidecars = ["", "-wal", "-shm"]
    return sidecars.reduce(Int64(0)) { total, suffix in
      let path = databaseURL.path + suffix
      let size =
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
        .int64Value ?? 0
      return total + size
    }
  }

  func beginIndexing(source: MailSourceDescriptor, fingerprint: SourceFingerprint) throws {
    guard let location = source.location else { throw MailIndexError.missingSourceLocation }
    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
      try execute(
        """
        INSERT INTO sources (
            id, name, kind, path, file_size, modified_at, fingerprint, status,
            last_indexed_at, message_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 0)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            kind = excluded.kind,
            path = excluded.path,
            file_size = excluded.file_size,
            modified_at = excluded.modified_at,
            fingerprint = excluded.fingerprint,
            status = excluded.status,
            message_count = 0
        """,
        [
          .text(source.id.uuidString), .text(source.name), .text(source.kind.rawValue),
          .text(location.path), .int(fingerprint.fileSize),
          .real(fingerprint.modificationDate?.timeIntervalSince1970),
          .text(fingerprint.lightweightHash), .text(MailIndexStatus.indexing.rawValue),
        ])
      try execute("DELETE FROM message_fts WHERE source_id = ?", [.text(source.id.uuidString)])
      try execute("DELETE FROM messages WHERE source_id = ?", [.text(source.id.uuidString)])
      try execute(
        """
        INSERT INTO indexing_state (
            source_id, status, indexed_count, bytes_indexed, started_at,
            updated_at, completed_at, error_message
        ) VALUES (?, ?, 0, 0, ?, ?, NULL, NULL)
        ON CONFLICT(source_id) DO UPDATE SET
            status = excluded.status,
            indexed_count = 0,
            bytes_indexed = 0,
            started_at = excluded.started_at,
            updated_at = excluded.updated_at,
            completed_at = NULL,
            error_message = NULL
        """,
        [
          .text(source.id.uuidString), .text(MailIndexStatus.indexing.rawValue),
          .real(Date().timeIntervalSince1970), .real(Date().timeIntervalSince1970),
        ])
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func insertBatch(_ entries: [IndexedMessageEntry], sourceID: UUID) throws {
    guard !entries.isEmpty else { return }
    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
      for entry in entries {
        try insert(entry, sourceID: sourceID)
      }
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func updateIndexingProgress(sourceID: UUID, indexedCount: Int, bytesIndexed: Int64) throws {
    try execute(
      """
      UPDATE indexing_state
      SET indexed_count = ?, bytes_indexed = ?, updated_at = ?
      WHERE source_id = ?
      """,
      [
        .int(Int64(indexedCount)), .int(bytesIndexed),
        .real(Date().timeIntervalSince1970), .text(sourceID.uuidString),
      ])
  }

  func finishIndexing(sourceID: UUID, status: MailIndexStatus, error: String? = nil) throws {
    let now = Date().timeIntervalSince1970
    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
      try execute(
        """
        UPDATE messages
        SET category_flags = category_flags | ?
        WHERE source_id = ? AND raw_sha256 IN (
            SELECT raw_sha256 FROM messages
            WHERE source_id = ?
            GROUP BY raw_sha256 HAVING COUNT(*) > 1
        )
        """,
        [
          .int(Int64(MessageClassificationFlags.duplicate.rawValue)),
          .text(sourceID.uuidString), .text(sourceID.uuidString),
        ])
      try execute(
        """
        UPDATE sources
        SET status = ?,
            last_indexed_at = CASE WHEN ? = ? THEN ? ELSE last_indexed_at END,
            message_count = (SELECT COUNT(*) FROM messages WHERE source_id = ?)
        WHERE id = ?
        """,
        [
          .text(status.rawValue), .text(status.rawValue),
          .text(MailIndexStatus.indexed.rawValue), .real(now),
          .text(sourceID.uuidString), .text(sourceID.uuidString),
        ])
      try execute(
        """
        UPDATE indexing_state
        SET status = ?, updated_at = ?, completed_at = ?, error_message = ?
        WHERE source_id = ?
        """,
        [
          .text(status.rawValue), .real(now), .real(now), .text(error),
          .text(sourceID.uuidString),
        ])
      try refreshMessageFlags(sourceID: sourceID)
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func sourceMetadata(sourceID: UUID) throws -> IndexedSourceMetadata? {
    try firstRow(
      """
      SELECT id, name, path, file_size, modified_at, fingerprint, message_count, status
      FROM sources
      WHERE id = ?
      """,
      [.text(sourceID.uuidString)]
    ) { statement in
      guard let id = UUID(uuidString: columnText(statement, 0) ?? "") else { return nil }
      return IndexedSourceMetadata(
        sourceID: id,
        name: columnText(statement, 1) ?? "",
        path: columnText(statement, 2) ?? "",
        fingerprint: SourceFingerprint(
          fileSize: sqlite3_column_int64(statement, 3),
          modificationDate: columnDate(statement, 4),
          lightweightHash: columnText(statement, 5) ?? ""
        ),
        messageCount: Int(sqlite3_column_int64(statement, 6)),
        databaseSize: sizeOnDisk,
        status: MailIndexStatus(rawValue: columnText(statement, 7) ?? "")
          ?? .notIndexed
      )
    }
  }

  func status(source: MailSourceDescriptor, currentFingerprint: SourceFingerprint?) throws
    -> MailIndexProgress
  {
    guard let metadata = try sourceMetadata(sourceID: source.id) else { return .notIndexed }
    var status = metadata.status
    if metadata.status == .indexed,
      let currentFingerprint,
      !currentFingerprint.matchesStored(metadata.fingerprint)
    {
      status = .stale
    }
    return MailIndexProgress(
      status: status,
      indexedMessages: metadata.messageCount,
      bytesIndexed: metadata.fingerprint.fileSize,
      databaseSize: metadata.databaseSize,
      detail: status.label
    )
  }

  func search(
    sourceID: UUID,
    query: ParsedSearchQuery,
    sort: MessageSortDescriptor = .newestFirst,
    limit: Int,
    offset: Int
  ) throws -> MailIndexPage {
    let boundedLimit = max(1, min(limit, 500))
    let boundedOffset = max(0, offset)
    let whereClause = try buildWhereClause(sourceID: sourceID, query: query)
    let orderBy = orderByClause(for: sort)
    let count = try scalarInt("SELECT COUNT(*) \(whereClause.sql)", whereClause.bindings)
    let rows = try allRows(
      """
      SELECT m.source_identifier, f.path, m.message_id, m.subject, m.sender,
             m.recipients_text, m.sent_at, m.byte_size, m.raw_sha256,
             m.has_attachments, m.file_path, m.source_offset, m.source_length,
             m.category_flags
      \(whereClause.sql)
      ORDER BY \(orderBy), m.id ASC
      LIMIT ? OFFSET ?
      """,
      whereClause.bindings + [.int(Int64(boundedLimit)), .int(Int64(boundedOffset))]
    ) { statement in
      MailMessageRecord(
        sourceIdentifier: columnText(statement, 0) ?? "",
        folderPath: columnText(statement, 1) ?? "",
        messageID: columnText(statement, 2),
        subject: columnText(statement, 3) ?? "",
        sender: columnText(statement, 4) ?? "",
        recipients: splitRecipients(columnText(statement, 5) ?? ""),
        sentDate: columnDate(statement, 6),
        byteSize: sqlite3_column_int64(statement, 7),
        rawSHA256: columnText(statement, 8) ?? "",
        hasAttachments: sqlite3_column_int(statement, 9) != 0,
        headers: [:],
        location: MessageStorageLocation(
          fileURL: URL(fileURLWithPath: columnText(statement, 10) ?? ""),
          byteOffset: UInt64(sqlite3_column_int64(statement, 11)),
          byteLength: sqlite3_column_int64(statement, 12)
        ),
        classificationFlags: MessageClassificationFlags(
          rawValue: Int(sqlite3_column_int64(statement, 13)))
      )
    }
    return MailIndexPage(messages: rows, totalCount: count)
  }

  func deleteIndex(for sourceID: UUID) throws {
    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
      try execute("DELETE FROM message_fts WHERE source_id = ?", [.text(sourceID.uuidString)])
      try execute("DELETE FROM messages WHERE source_id = ?", [.text(sourceID.uuidString)])
      try execute("DELETE FROM indexing_state WHERE source_id = ?", [.text(sourceID.uuidString)])
      try execute("DELETE FROM folders WHERE source_id = ?", [.text(sourceID.uuidString)])
      try execute("DELETE FROM sources WHERE id = ?", [.text(sourceID.uuidString)])
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func saveRecoveryReport(_ report: RecoveryReport) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let summaryJSON = String(data: try report.jsonData(), encoding: .utf8) ?? "{}"

    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
      try execute(
        """
        INSERT INTO recovery_scan_runs (
            id, source_id, source_name, scanner_version, status, started_at,
            completed_at, source_file_size, source_modified_at, source_fingerprint,
            message_count, byte_count, issue_count, report_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            status = excluded.status,
            completed_at = excluded.completed_at,
            source_file_size = excluded.source_file_size,
            source_modified_at = excluded.source_modified_at,
            source_fingerprint = excluded.source_fingerprint,
            message_count = excluded.message_count,
            byte_count = excluded.byte_count,
            issue_count = excluded.issue_count,
            report_json = excluded.report_json
        """,
        [
          .text(report.id.uuidString),
          .text(report.sourceID.uuidString),
          .text(report.sourceName),
          .text(report.scannerVersion),
          .text(RecoveryScanStatus.completed.rawValue),
          .real(report.startedAt.timeIntervalSince1970),
          .real(report.completedAt.timeIntervalSince1970),
          .int(report.sourceFingerprint.fileSize),
          .real(report.sourceFingerprint.modificationDate?.timeIntervalSince1970),
          .text(report.sourceFingerprint.lightweightHash),
          .int(Int64(report.totalMessagesScanned)),
          .int(report.totalBytesScanned),
          .int(Int64(report.totalIssues)),
          .text(summaryJSON),
        ])
      try execute("DELETE FROM recovery_issues WHERE run_id = ?", [.text(report.id.uuidString)])
      try execute(
        "DELETE FROM recovery_repair_proposals WHERE run_id = ?",
        [.text(report.id.uuidString)]
      )
      for issue in report.issues {
        let evidenceJSON =
          String(data: try encoder.encode(issue.evidence), encoding: .utf8) ?? "{}"
        try execute(
          """
          INSERT INTO recovery_issues (
              id, run_id, source_id, message_summary_id, kind, severity, confidence,
              title, technical_explanation, byte_offset, byte_length, repairable,
              suggested_action, evidence_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            .text(issue.id),
            .text(report.id.uuidString),
            .text(issue.sourceID.uuidString),
            .text(issue.messageSummaryID),
            .text(issue.kind.rawValue),
            .text(issue.severity.rawValue),
            .text(issue.confidence.rawValue),
            .text(issue.title),
            .text(issue.technicalExplanation),
            .int(issue.byteOffset.map(Int64.init) ?? 0),
            .int(issue.byteLength ?? 0),
            .int(issue.isSafelyRepairable ? 1 : 0),
            .text(issue.suggestedAction.rawValue),
            .text(evidenceJSON),
          ])
      }
      for proposal in report.suggestions {
        try execute(
          """
          INSERT INTO recovery_repair_proposals (
              id, run_id, issue_id, action, original_condition, proposed_change,
              confidence, changes_raw_bytes, metadata_only, requires_user_confirmation
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            .text(proposal.id),
            .text(report.id.uuidString),
            .text(proposal.issueID),
            .text(proposal.action.rawValue),
            .text(proposal.originalCondition),
            .text(proposal.proposedChange),
            .text(proposal.confidence.rawValue),
            .int(proposal.changesRawBytes ? 1 : 0),
            .int(proposal.metadataOnly ? 1 : 0),
            .int(proposal.requiresUserConfirmation ? 1 : 0),
          ])
      }
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func latestRecoveryReport(
    sourceID: UUID,
    currentFingerprint: SourceFingerprint?
  ) throws -> RecoveryReport? {
    guard
      let row = try firstRow(
        """
        SELECT report_json, source_file_size, source_modified_at, source_fingerprint
        FROM recovery_scan_runs
        WHERE source_id = ?
        ORDER BY completed_at DESC
        LIMIT 1
        """,
        [.text(sourceID.uuidString)],
        map: { statement in
          (
            columnText(statement, 0),
            sqlite3_column_int64(statement, 1),
            columnDate(statement, 2),
            columnText(statement, 3)
          )
        }),
      let reportJSON = row.0,
      let data = reportJSON.data(using: .utf8)
    else {
      return nil
    }

    if let currentFingerprint {
      let stored = SourceFingerprint(
        fileSize: row.1,
        modificationDate: row.2,
        lightweightHash: row.3 ?? ""
      )
      guard currentFingerprint.matchesStored(stored) else { return nil }
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(RecoveryReport.self, from: data)
  }

  func schemaVersion() throws -> Int {
    try scalarInt("SELECT version FROM schema_version ORDER BY version DESC LIMIT 1", [])
  }

  private func migrateIfNeeded() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS schema_version (
          version INTEGER NOT NULL PRIMARY KEY,
          applied_at REAL NOT NULL
      )
      """)
    let version = (try? schemaVersion()) ?? 0
    guard version < Self.currentSchemaVersion else { return }

    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
      if version < 1 {
        try migrateToVersion1()
      }
      if version < 2 {
        try migrateToVersion2()
      }
      try execute(
        "INSERT OR REPLACE INTO schema_version (version, applied_at) VALUES (?, ?)",
        [.int(Int64(Self.currentSchemaVersion)), .real(Date().timeIntervalSince1970)]
      )
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func migrateToVersion1() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS sources (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          path TEXT NOT NULL,
          file_size INTEGER NOT NULL,
          modified_at REAL,
          fingerprint TEXT NOT NULL,
          status TEXT NOT NULL,
          last_indexed_at REAL,
          message_count INTEGER NOT NULL DEFAULT 0
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS folders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
          path TEXT NOT NULL,
          UNIQUE(source_id, path)
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
          folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
          source_identifier TEXT NOT NULL,
          file_path TEXT NOT NULL,
          source_offset INTEGER NOT NULL,
          source_length INTEGER NOT NULL,
          message_id TEXT,
          subject TEXT NOT NULL,
          sender TEXT NOT NULL,
          recipients_text TEXT NOT NULL,
          sent_at REAL,
          byte_size INTEGER NOT NULL,
          raw_sha256 TEXT NOT NULL,
          has_attachments INTEGER NOT NULL,
          attachment_count INTEGER NOT NULL,
          category_flags INTEGER NOT NULL,
          preview_excerpt TEXT NOT NULL,
          indexed_at REAL NOT NULL,
          UNIQUE(source_id, source_identifier)
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS recipients (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          address TEXT NOT NULL
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS attachments (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          attachment_identifier TEXT NOT NULL,
          filename TEXT,
          mime_type TEXT NOT NULL,
          byte_size INTEGER NOT NULL,
          content_id TEXT,
          disposition TEXT,
          transfer_encoding TEXT NOT NULL,
          lazy_reference TEXT
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS message_flags (
          message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          flag TEXT NOT NULL,
          PRIMARY KEY(message_id, flag)
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS indexing_state (
          source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
          status TEXT NOT NULL,
          indexed_count INTEGER NOT NULL,
          bytes_indexed INTEGER NOT NULL,
          started_at REAL,
          updated_at REAL,
          completed_at REAL,
          error_message TEXT
      )
      """)
    try execute(
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
          source_id UNINDEXED,
          message_pk UNINDEXED,
          subject,
          sender,
          recipients,
          preview_text
      )
      """)
    try execute("CREATE INDEX IF NOT EXISTS idx_folders_source_path ON folders(source_id, path)")
    try execute(
      "CREATE INDEX IF NOT EXISTS idx_messages_source_date ON messages(source_id, sent_at)")
    try execute(
      "CREATE INDEX IF NOT EXISTS idx_messages_source_sender ON messages(source_id, sender)")
    try execute(
      "CREATE INDEX IF NOT EXISTS idx_messages_source_hash ON messages(source_id, raw_sha256)")
    try execute(
      "CREATE INDEX IF NOT EXISTS idx_messages_source_size ON messages(source_id, byte_size)")
    try execute(
      "CREATE INDEX IF NOT EXISTS idx_messages_source_flags ON messages(source_id, category_flags)")
    try execute("CREATE INDEX IF NOT EXISTS idx_recipients_address ON recipients(address)")
    try execute("CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_id)")
  }

  private func migrateToVersion2() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS recovery_scan_runs (
          id TEXT PRIMARY KEY,
          source_id TEXT NOT NULL,
          source_name TEXT NOT NULL,
          scanner_version TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at REAL NOT NULL,
          completed_at REAL,
          source_file_size INTEGER NOT NULL,
          source_modified_at REAL,
          source_fingerprint TEXT NOT NULL,
          message_count INTEGER NOT NULL,
          byte_count INTEGER NOT NULL,
          issue_count INTEGER NOT NULL,
          report_json TEXT NOT NULL
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS recovery_issues (
          id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES recovery_scan_runs(id) ON DELETE CASCADE,
          source_id TEXT NOT NULL,
          message_summary_id TEXT,
          kind TEXT NOT NULL,
          severity TEXT NOT NULL,
          confidence TEXT NOT NULL,
          title TEXT NOT NULL,
          technical_explanation TEXT NOT NULL,
          byte_offset INTEGER,
          byte_length INTEGER,
          repairable INTEGER NOT NULL,
          suggested_action TEXT NOT NULL,
          evidence_json TEXT NOT NULL
      )
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS recovery_repair_proposals (
          id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES recovery_scan_runs(id) ON DELETE CASCADE,
          issue_id TEXT NOT NULL REFERENCES recovery_issues(id) ON DELETE CASCADE,
          action TEXT NOT NULL,
          original_condition TEXT NOT NULL,
          proposed_change TEXT NOT NULL,
          confidence TEXT NOT NULL,
          changes_raw_bytes INTEGER NOT NULL,
          metadata_only INTEGER NOT NULL,
          requires_user_confirmation INTEGER NOT NULL
      )
      """)
    try execute(
      "CREATE INDEX IF NOT EXISTS idx_recovery_runs_source ON recovery_scan_runs(source_id, completed_at)"
    )
    try execute(
      "CREATE INDEX IF NOT EXISTS idx_recovery_issues_run_kind ON recovery_issues(run_id, kind)"
    )
    try execute(
      "CREATE INDEX IF NOT EXISTS idx_recovery_issues_run_severity ON recovery_issues(run_id, severity)"
    )
  }

  private func insert(_ entry: IndexedMessageEntry, sourceID: UUID) throws {
    let folderID = try folderID(sourceID: sourceID, path: entry.record.folderPath)
    try execute(
      """
      INSERT INTO messages (
          source_id, folder_id, source_identifier, file_path, source_offset, source_length,
          message_id, subject, sender, recipients_text, sent_at, byte_size, raw_sha256,
          has_attachments, attachment_count, category_flags, preview_excerpt, indexed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(sourceID.uuidString), .int(Int64(folderID)),
        .text(entry.record.sourceIdentifier), .text(entry.filePath),
        .int(Int64(entry.sourceOffset)), .int(entry.sourceLength),
        .text(entry.record.messageID), .text(entry.record.subject),
        .text(entry.record.sender), .text(entry.record.recipients.joined(separator: "\n")),
        .real(entry.record.sentDate?.timeIntervalSince1970),
        .int(entry.record.byteSize), .text(entry.record.rawSHA256),
        .int(entry.record.hasAttachments ? 1 : 0),
        .int(Int64(entry.attachments.count)),
        .int(Int64(entry.record.classificationFlags.rawValue)),
        .text(entry.previewExcerpt), .real(Date().timeIntervalSince1970),
      ])
    let messagePK = sqlite3_last_insert_rowid(db)
    for recipient in entry.record.recipients {
      try execute(
        "INSERT INTO recipients (message_id, address) VALUES (?, ?)",
        [.int(messagePK), .text(recipient)]
      )
    }
    for attachment in entry.attachments {
      try execute(
        """
        INSERT INTO attachments (
            message_id, attachment_identifier, filename, mime_type, byte_size,
            content_id, disposition, transfer_encoding, lazy_reference
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .int(messagePK), .text(attachment.id), .text(attachment.filename),
          .text(attachment.mimeType), .int(attachment.byteSize),
          .text(attachment.contentID), .text(attachment.disposition),
          .text(attachment.transferEncoding), .text(attachment.lazyReference),
        ])
    }
    try insertFlags(entry.record.classificationFlags, messagePK: messagePK)
    try execute(
      """
      INSERT INTO message_fts (
          source_id, message_pk, subject, sender, recipients, preview_text
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        .text(sourceID.uuidString), .int(messagePK), .text(entry.record.subject),
        .text(entry.record.sender), .text(entry.record.recipients.joined(separator: " ")),
        .text(entry.previewExcerpt),
      ])
  }

  private func refreshMessageFlags(sourceID: UUID) throws {
    try execute(
      """
      DELETE FROM message_flags
      WHERE message_id IN (SELECT id FROM messages WHERE source_id = ?)
      """,
      [.text(sourceID.uuidString)]
    )
    let rows = try allRows(
      "SELECT id, category_flags FROM messages WHERE source_id = ?",
      [.text(sourceID.uuidString)]
    ) { statement in
      (sqlite3_column_int64(statement, 0), Int(sqlite3_column_int64(statement, 1)))
    }
    for row in rows {
      try insertFlags(MessageClassificationFlags(rawValue: row.1), messagePK: row.0)
    }
  }

  private func insertFlags(_ flags: MessageClassificationFlags, messagePK: Int64) throws {
    let namedFlags: [(MessageClassificationFlags, String)] = [
      (.duplicate, "duplicate"),
      (.newsletter, "newsletter"),
      (.oneTimeCode, "otp"),
      (.sensitive, "sensitive"),
      (.large, "large"),
    ]
    for (flag, name) in namedFlags where flags.contains(flag) {
      try execute(
        "INSERT OR IGNORE INTO message_flags (message_id, flag) VALUES (?, ?)",
        [.int(messagePK), .text(name)]
      )
    }
  }

  private func folderID(sourceID: UUID, path: String) throws -> Int64 {
    try execute(
      "INSERT OR IGNORE INTO folders (source_id, path) VALUES (?, ?)",
      [.text(sourceID.uuidString), .text(path)]
    )
    return Int64(
      try scalarInt(
        "SELECT id FROM folders WHERE source_id = ? AND path = ?",
        [.text(sourceID.uuidString), .text(path)]
      ))
  }

  private func buildWhereClause(sourceID: UUID, query: ParsedSearchQuery) throws
    -> (sql: String, bindings: [SQLiteBinding])
  {
    var joins = "FROM messages m JOIN folders f ON f.id = m.folder_id"
    var conditions = ["m.source_id = ?"]
    var bindings: [SQLiteBinding] = [.text(sourceID.uuidString)]

    if let ftsQuery = query.ftsQuery {
      joins += " JOIN message_fts ON message_fts.message_pk = m.id"
      conditions.append("message_fts MATCH ?")
      bindings.append(.text(ftsQuery))
    }

    for filter in query.filters {
      switch filter {
      case .senderContains(let value):
        conditions.append("m.sender LIKE ? ESCAPE '\\'")
        bindings.append(.text("%\(escapeLike(value))%"))
      case .recipientContains(let value):
        conditions.append(
          "EXISTS (SELECT 1 FROM recipients r WHERE r.message_id = m.id AND r.address LIKE ? ESCAPE '\\')"
        )
        bindings.append(.text("%\(escapeLike(value))%"))
      case .hasAttachment:
        conditions.append("m.has_attachments = 1")
      case .category(let flag):
        conditions.append("(m.category_flags & ?) != 0")
        bindings.append(.int(Int64(flag.rawValue)))
      case .largerThanBytes(let bytes):
        conditions.append("m.byte_size > ?")
        bindings.append(.int(bytes))
      case .before(let date):
        conditions.append("m.sent_at < ?")
        bindings.append(.real(date.timeIntervalSince1970))
      case .after(let date):
        conditions.append("m.sent_at > ?")
        bindings.append(.real(date.timeIntervalSince1970))
      }
    }

    return ("\(joins) WHERE \(conditions.joined(separator: " AND "))", bindings)
  }

  private func orderByClause(for sort: MessageSortDescriptor) -> String {
    let direction = sort.ascending ? "ASC" : "DESC"
    switch sort.column {
    case .date:
      return "m.sent_at \(direction)"
    case .sender:
      return "m.sender COLLATE NOCASE \(direction)"
    case .subject:
      return "m.subject COLLATE NOCASE \(direction)"
    case .size:
      return "m.byte_size \(direction)"
    case .attachment:
      return "m.has_attachments \(direction)"
    case .category:
      return """
        CASE
        WHEN m.category_flags = 0 THEN 'Běžné'
        WHEN (m.category_flags & \(MessageClassificationFlags.sensitive.rawValue)) != 0 THEN 'Citlivé'
        WHEN (m.category_flags & \(MessageClassificationFlags.duplicate.rawValue)) != 0 THEN 'Duplicitní'
        WHEN (m.category_flags & \(MessageClassificationFlags.newsletter.rawValue)) != 0 THEN 'Newsletter'
        WHEN (m.category_flags & \(MessageClassificationFlags.oneTimeCode.rawValue)) != 0 THEN 'OTP'
        WHEN (m.category_flags & \(MessageClassificationFlags.large.rawValue)) != 0 THEN 'Velké'
        ELSE ''
        END COLLATE NOCASE \(direction)
        """
    }
  }

  private func escapeLike(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  private func execute(_ sql: String, _ bindings: [SQLiteBinding] = []) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE {
        return
      }
      guard result == SQLITE_ROW else {
        throw sqliteError()
      }
    }
  }

  private func firstRow<T>(
    _ sql: String,
    _ bindings: [SQLiteBinding],
    map: (OpaquePointer?) throws -> T?
  ) throws -> T? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW { return try map(statement) }
    if result == SQLITE_DONE { return nil }
    throw sqliteError()
  }

  private func allRows<T>(
    _ sql: String,
    _ bindings: [SQLiteBinding],
    map: (OpaquePointer?) throws -> T
  ) throws -> [T] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    var rows: [T] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW {
        rows.append(try map(statement))
      } else if result == SQLITE_DONE {
        return rows
      } else {
        throw sqliteError()
      }
    }
  }

  private func scalarInt(_ sql: String, _ bindings: [SQLiteBinding]) throws -> Int {
    try firstRow(sql, bindings) { statement in
      Int(sqlite3_column_int64(statement, 0))
    } ?? 0
  }

  private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
    for (index, binding) in bindings.enumerated() {
      let position = Int32(index + 1)
      let result: Int32
      switch binding {
      case .int(let value):
        result = sqlite3_bind_int64(statement, position, value)
      case .real(let value):
        if let value {
          result = sqlite3_bind_double(statement, position, value)
        } else {
          result = sqlite3_bind_null(statement, position)
        }
      case .text(let value):
        if let value {
          result = value.withCString { pointer in
            sqlite3_bind_text(statement, position, pointer, -1, sqliteTransient)
          }
        } else {
          result = sqlite3_bind_null(statement, position)
        }
      }
      guard result == SQLITE_OK else { throw sqliteError() }
    }
  }

  private func sqliteError() -> MailIndexError {
    MailIndexError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
  }
}

struct IndexedMessageEntry: Sendable {
  var record: MailMessageRecord
  var previewExcerpt: String
  var attachments: [MessageAttachmentMetadata]
  var filePath: String
  var sourceOffset: UInt64
  var sourceLength: Int64
}

private enum SQLiteBinding {
  case int(Int64)
  case real(TimeInterval?)
  case text(String?)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
  guard let text = sqlite3_column_text(statement, index) else { return nil }
  return String(cString: text)
}

private func columnDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
  guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
  return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
}

private func splitRecipients(_ value: String) -> [String] {
  value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

extension SourceFingerprint {
  fileprivate func matchesStored(_ stored: SourceFingerprint) -> Bool {
    fileSize == stored.fileSize && lightweightHash == stored.lightweightHash
  }
}
