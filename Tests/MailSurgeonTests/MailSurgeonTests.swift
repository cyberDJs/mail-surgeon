import XCTest
@testable import MailSurgeon

final class MailSurgeonTests: XCTestCase {
    func testEmptyAnalysis() {
        XCTAssertEqual(MailboxAnalysis.empty.totalMessages, 0)
        XCTAssertEqual(MailboxAnalysis.empty.totalBytes, 0)
    }

    func testFactoryReturnsMBOXConnector() {
        let descriptor = MailSourceDescriptor(
            name: "fixture.mbox",
            kind: .mbox,
            location: URL(fileURLWithPath: "/tmp/fixture.mbox")
        )

        let connector = ConnectorFactory().makeConnector(for: descriptor)

        XCTAssertTrue(connector is MBOXConnector)
    }

    func testRFC2047Base64HeaderDecoding() {
        let decoded = RFC2047Decoder().decode("=?UTF-8?B?SmFuIEtvxI3DrQ==?=")

        XCTAssertEqual(decoded, "Jan Kočí")
    }

    func testRFC2047QuotedPrintableHeaderDecoding() {
        let decoded = RFC2047Decoder().decode("=?ISO-8859-1?Q?Andr=E9_Dupont?=")

        XCTAssertEqual(decoded, "André Dupont")
    }

    @MainActor
    func testAnalyzerScansGeneratedMBOXFixture() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("analysis.mbox")
        let duplicateMessage = message(
            id: "duplicate@example.test",
            subject: "Invoice for review",
            extraHeaders: [],
            body: "Same body\n"
        )
        let otpMessage = message(
            id: "otp@example.test",
            subject: "Your verification code",
            extraHeaders: [],
            body: "Use 123456 to sign in.\n"
        )
        let newsletterMessage = message(
            id: "newsletter@example.test",
            subject: "Weekly update",
            extraHeaders: ["List-Unsubscribe: <mailto:unsubscribe@example.test>"],
            body: "News\n"
        )
        try writeMBOX(
            messages: [duplicateMessage, duplicateMessage, otpMessage, newsletterMessage],
            to: fileURL
        )

        let descriptor = MailSourceDescriptor(name: "analysis.mbox", kind: .mbox, location: fileURL)
        var progressEvents: [AnalysisProgress] = []

        let analysis = try await MailAnalyzer().analyze(source: descriptor) { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(analysis.totalMessages, 4)
        XCTAssertEqual(analysis.totalBytes, Int64(
            Data(duplicateMessage.utf8).count
                + Data(duplicateMessage.utf8).count
                + Data(otpMessage.utf8).count
                + Data(newsletterMessage.utf8).count
        ))
        XCTAssertEqual(analysis.exactDuplicates, 1)
        XCTAssertEqual(analysis.likelyNewsletters, 1)
        XCTAssertEqual(analysis.likelyOneTimeCodes, 1)
        XCTAssertEqual(analysis.largeMessages, 0)
        XCTAssertEqual(analysis.sensitiveCandidates, 2)
        XCTAssertEqual(progressEvents.last?.messagesScanned, 4)
        XCTAssertEqual(progressEvents.last?.bytesScanned, analysis.totalBytes)
    }

    func testMBOXConnectorScansMailboxBundleDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let bundleURL = directory.appendingPathComponent("Archive.mbox")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try writeMBOX(
            messages: [
                message(
                    id: "bundle@example.test",
                    subject: "Bundled message",
                    extraHeaders: [],
                    body: "Stored inside a mailbox bundle.\n"
                )
            ],
            to: bundleURL.appendingPathComponent("mbox")
        )

        let descriptor = MailSourceDescriptor(name: "Archive.mbox", kind: .mbox, location: bundleURL)
        let connector = MBOXConnector(descriptor: descriptor)
        var records: [MailMessageRecord] = []

        try await connector.validateAccess()
        for try await record in connector.scanMessages() {
            records.append(record)
        }

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.folderPath, "Archive")
        XCTAssertEqual(records.first?.subject, "Bundled message")
    }

    func testMessageBrowserMarksDuplicateHashes() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("duplicates.mbox")
        let duplicateMessage = message(
            id: "duplicate@example.test",
            subject: "Duplicate",
            extraHeaders: [],
            body: "Same body\n"
        )
        try writeMBOX(messages: [duplicateMessage, duplicateMessage], to: fileURL)

        let records = try await MessageBrowser().loadSummaries(
            source: MailSourceDescriptor(name: "duplicates.mbox", kind: .mbox, location: fileURL)
        )

        XCTAssertEqual(Set(records.map(\.rawSHA256)).count, 1)
        XCTAssertTrue(records.allSatisfy { $0.classificationFlags.contains(.duplicate) })
    }

    func testMessageFilteringSearchesAndFiltersClassifications() {
        let browser = MessageBrowser()
        let records = [
            record(
                subject: "Monthly newsletter",
                sender: "News <news@example.test>",
                recipients: ["Jan <jan@example.test>"],
                flags: [.newsletter]
            ),
            record(
                subject: "Your verification code",
                sender: "Auth <auth@example.test>",
                recipients: ["Security <security@example.test>"],
                flags: [.oneTimeCode]
            ),
            record(
                subject: "Bank contract",
                sender: "Legal <legal@example.test>",
                recipients: ["Archive <archive@example.test>"],
                flags: [.sensitive]
            )
        ]

        let searchMatches = browser.filter(records: records, searchText: "security", enabledFilters: [])
        let filtered = browser.filter(records: records, searchText: "", enabledFilters: [.newsletters, .sensitive])

        XCTAssertEqual(searchMatches.map(\.subject), ["Your verification code"])
        XCTAssertEqual(filtered.map(\.subject), ["Monthly newsletter", "Bank contract"])
    }

    func testMessageSortingByDateSenderSubjectSizeAttachmentAndCategory() {
        let browser = MessageBrowser()
        let older = date(year: 2025, month: 1, day: 1)
        let newer = date(year: 2026, month: 1, day: 1)
        let records = [
            record(subject: "Beta", sender: "Zed", sentDate: older, byteSize: 20, hasAttachments: false, flags: [.newsletter]),
            record(subject: "Alpha", sender: "Amy", sentDate: newer, byteSize: 10, hasAttachments: true, flags: [.oneTimeCode])
        ]

        XCTAssertEqual(browser.sort(records: records, descriptor: .init(column: .date, ascending: true)).map(\.subject), ["Beta", "Alpha"])
        XCTAssertEqual(browser.sort(records: records, descriptor: .init(column: .sender, ascending: true)).map(\.sender), ["Amy", "Zed"])
        XCTAssertEqual(browser.sort(records: records, descriptor: .init(column: .subject, ascending: true)).map(\.subject), ["Alpha", "Beta"])
        XCTAssertEqual(browser.sort(records: records, descriptor: .init(column: .size, ascending: true)).map(\.byteSize), [10, 20])
        XCTAssertEqual(browser.sort(records: records, descriptor: .init(column: .attachment, ascending: false)).map(\.hasAttachments), [true, false])
        XCTAssertEqual(browser.sort(records: records, descriptor: .init(column: .category, ascending: true)).map(\.categoryLabel), ["Newsletter", "OTP"])
    }

    func testMBOXConnectorStoresMessageOffsetsAndLengths() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("offsets.mbox")
        let first = message(id: "first@example.test", subject: "First", extraHeaders: [], body: "First body\n")
        let second = message(id: "second@example.test", subject: "Second", extraHeaders: [], body: "Second body\n")
        try writeMBOX(messages: [first, second], to: fileURL)

        let records = try await scan(fileURL)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].location?.byteLength, Int64(Data(first.utf8).count))
        XCTAssertEqual(records[1].location?.byteLength, Int64(Data(second.utf8).count))
        XCTAssertEqual(try slice(record: records[0]), first)
        XCTAssertEqual(try slice(record: records[1]), second)
    }

    func testMessageBrowserLoadsSelectedMessageOnDemand() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("detail.mbox")
        let first = message(id: "first@example.test", subject: "First", extraHeaders: [], body: "First body should stay out.\n")
        let second = message(id: "second@example.test", subject: "Second", extraHeaders: [], body: "Second body preview.\n")
        try writeMBOX(messages: [first, second], to: fileURL)

        let records = try await scan(fileURL)
        let detail = try await MessageBrowser().loadDetail(for: records[1])

        XCTAssertEqual(detail.metadata["Subject"], "Second")
        XCTAssertEqual(detail.rawByteSize, Int64(Data(second.utf8).count))
        XCTAssertTrue(detail.plainTextPreview?.contains("Second body preview.") == true)
        XCTAssertFalse(detail.plainTextPreview?.contains("First body should stay out.") == true)
    }

    func testEmptyMBOXThrowsEmptyArchive() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("empty.mbox")
        try Data().write(to: fileURL)
        let descriptor = MailSourceDescriptor(name: "empty.mbox", kind: .mbox, location: fileURL)

        do {
            _ = try await MailAnalyzer().analyze(source: descriptor)
            XCTFail("Expected empty archive error.")
        } catch ConnectorError.emptyArchive {
            // Expected.
        } catch {
            XCTFail("Expected empty archive error, got \(error).")
        }
    }

    func testMalformedMBOXThrowsMalformedArchive() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("malformed.mbox")
        try "Subject: Missing delimiter\n\nBody\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let descriptor = MailSourceDescriptor(name: "malformed.mbox", kind: .mbox, location: fileURL)

        do {
            _ = try await MailAnalyzer().analyze(source: descriptor)
            XCTFail("Expected malformed archive error.")
        } catch ConnectorError.malformedArchive {
            // Expected.
        } catch {
            XCTFail("Expected malformed archive error, got \(error).")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSurgeonTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMBOX(messages: [String], to url: URL) throws {
        let content = messages.enumerated().map { index, message in
            "From sender\(index)@example.test Thu Jan 01 00:00:00 2026\n\(message)"
        }.joined()
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func message(id: String, subject: String, extraHeaders: [String], body: String) -> String {
        var headers = [
            "Message-ID: <\(id)>",
            "Subject: \(subject)",
            "From: Sender <sender@example.test>",
            "To: Recipient <recipient@example.test>",
            "Date: Thu, 1 Jan 2026 00:00:00 +0000"
        ]
        headers.append(contentsOf: extraHeaders)
        return headers.joined(separator: "\n") + "\n\n" + body
    }

    private func scan(_ fileURL: URL) async throws -> [MailMessageRecord] {
        let descriptor = MailSourceDescriptor(name: fileURL.lastPathComponent, kind: .mbox, location: fileURL)
        let connector = MBOXConnector(descriptor: descriptor)
        var records: [MailMessageRecord] = []
        for try await record in connector.scanMessages() {
            records.append(record)
        }
        return records
    }

    private func slice(record: MailMessageRecord) throws -> String {
        guard let location = record.location else {
            XCTFail("Missing storage location.")
            return ""
        }

        let handle = try FileHandle(forReadingFrom: location.fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: location.byteOffset)
        let data = try XCTUnwrap(try handle.read(upToCount: Int(location.byteLength)))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func record(
        subject: String,
        sender: String,
        recipients: [String] = [],
        sentDate: Date? = nil,
        byteSize: Int64 = 1,
        hasAttachments: Bool = false,
        flags: MessageClassificationFlags = []
    ) -> MailMessageRecord {
        MailMessageRecord(
            sourceIdentifier: UUID().uuidString,
            folderPath: "INBOX",
            messageID: nil,
            subject: subject,
            sender: sender,
            recipients: recipients,
            sentDate: sentDate,
            byteSize: byteSize,
            rawSHA256: UUID().uuidString,
            hasAttachments: hasAttachments,
            headers: [:],
            classificationFlags: flags
        )
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day
        ).date!
    }
}
