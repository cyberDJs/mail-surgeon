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
}
