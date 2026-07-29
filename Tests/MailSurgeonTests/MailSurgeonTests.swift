import XCTest
@testable import MailSurgeon

final class MailSurgeonTests: XCTestCase {
    func testEmptyAnalysis() {
        XCTAssertEqual(MailboxAnalysis.empty.totalMessages, 0)
        XCTAssertEqual(MailboxAnalysis.empty.totalBytes, 0)
    }
}
