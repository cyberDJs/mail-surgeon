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
    XCTAssertEqual(
      analysis.totalBytes,
      Int64(
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

    let descriptor = MailSourceDescriptor(
      name: "Archive.mbox", kind: .mbox, location: bundleURL)
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
      ),
    ]

    let searchMatches = browser.filter(
      records: records, searchText: "security", enabledFilters: [])
    let filtered = browser.filter(
      records: records, searchText: "", enabledFilters: [.newsletters, .sensitive])

    XCTAssertEqual(searchMatches.map(\.subject), ["Your verification code"])
    XCTAssertEqual(filtered.map(\.subject), ["Monthly newsletter", "Bank contract"])
  }

  func testMessageSortingByDateSenderSubjectSizeAttachmentAndCategory() {
    let browser = MessageBrowser()
    let older = date(year: 2025, month: 1, day: 1)
    let newer = date(year: 2026, month: 1, day: 1)
    let records = [
      record(
        subject: "Beta", sender: "Zed", sentDate: older, byteSize: 20,
        hasAttachments: false,
        flags: [.newsletter]),
      record(
        subject: "Alpha", sender: "Amy", sentDate: newer, byteSize: 10,
        hasAttachments: true,
        flags: [.oneTimeCode]),
    ]

    XCTAssertEqual(
      browser.sort(records: records, descriptor: .init(column: .date, ascending: true)).map(
        \.subject), ["Beta", "Alpha"])
    XCTAssertEqual(
      browser.sort(records: records, descriptor: .init(column: .sender, ascending: true)).map(
        \.sender), ["Amy", "Zed"])
    XCTAssertEqual(
      browser.sort(records: records, descriptor: .init(column: .subject, ascending: true))
        .map(
          \.subject), ["Alpha", "Beta"])
    XCTAssertEqual(
      browser.sort(records: records, descriptor: .init(column: .size, ascending: true)).map(
        \.byteSize), [10, 20])
    XCTAssertEqual(
      browser.sort(records: records, descriptor: .init(column: .attachment, ascending: false))
        .map(
          \.hasAttachments), [true, false])
    XCTAssertEqual(
      browser.sort(records: records, descriptor: .init(column: .category, ascending: true))
        .map(
          \.categoryLabel), ["Newsletter", "OTP"])
  }

  @MainActor
  func testAppModelSearchQueryStateFiltersInMemoryMessages() {
    let model = AppModel(savePanelProvider: FakeSavePanelProvider())
    model.indexProgress = .notIndexed
    model.messages = [
      record(subject: "Invoice", sender: "Billing <billing@example.test>"),
      record(subject: "Newsletter", sender: "News <news@example.test>"),
    ]

    model.updateMessageSearchText("billing")

    XCTAssertEqual(model.messageSearchText, "billing")
    XCTAssertEqual(model.displayedMessages.map(\.subject), ["Invoice"])
  }

  func testMessageSortDescriptorMapsTableSortOrderAndToggle() throws {
    let senderSort = MessageSortDescriptor(
      sortOrder: [KeyPathComparator(\MailMessageRecord.sender, order: .forward)]
    )

    XCTAssertEqual(senderSort, MessageSortDescriptor(column: .sender, ascending: true))
    XCTAssertEqual(senderSort?.toggled(), MessageSortDescriptor(column: .sender, ascending: false))
    XCTAssertEqual(
      MessageSortDescriptor(column: .size, ascending: false).sortOrder.first?.keyPath,
      \MailMessageRecord.byteSize
    )
    XCTAssertEqual(
      MessageSortDescriptor(column: .size, ascending: false).sortOrder.first?.order,
      .reverse
    )
  }

  @MainActor
  func testAppModelAscendingDescendingSortToggleState() {
    let model = AppModel(savePanelProvider: FakeSavePanelProvider())

    model.updateMessageSortDescriptor(.init(column: .sender, ascending: true))
    XCTAssertEqual(model.messageSortDescriptor, .init(column: .sender, ascending: true))
    XCTAssertEqual(model.tableSortOrder.first?.order, .forward)

    model.updateMessageSortDescriptor(model.messageSortDescriptor.toggled())
    XCTAssertEqual(model.messageSortDescriptor, .init(column: .sender, ascending: false))
    XCTAssertEqual(model.tableSortOrder.first?.order, .reverse)
  }

  func testMBOXConnectorStoresMessageOffsetsAndLengths() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("offsets.mbox")
    let first = message(
      id: "first@example.test", subject: "First", extraHeaders: [], body: "First body\n")
    let second = message(
      id: "second@example.test", subject: "Second", extraHeaders: [], body: "Second body\n")
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
    let first = message(
      id: "first@example.test", subject: "First", extraHeaders: [],
      body: "First body should stay out.\n")
    let second = message(
      id: "second@example.test", subject: "Second", extraHeaders: [],
      body: "Second body preview.\n"
    )
    try writeMBOX(messages: [first, second], to: fileURL)

    let records = try await scan(fileURL)
    let detail = try await MessageBrowser().loadDetail(for: records[1])

    XCTAssertEqual(detail.metadata["Subject"], "Second")
    XCTAssertEqual(detail.rawByteSize, Int64(Data(second.utf8).count))
    XCTAssertTrue(detail.plainTextPreview?.contains("Second body preview.") == true)
    XCTAssertFalse(detail.plainTextPreview?.contains("First body should stay out.") == true)
  }

  func testMIMEParserPrefersPlainTextFromMultipartAlternative() throws {
    let data = mimeMessage(
      headers: ["Content-Type: multipart/alternative; boundary=\"alt\""],
      body: """
        --alt
        Content-Type: text/html; charset=utf-8

        <html><body>HTML body</body></html>
        --alt
        Content-Type: text/plain; charset=utf-8

        Plain body
        --alt--

        """
    )

    let parsed = MIMEParser().parse(data)

    XCTAssertEqual(parsed.safePlainTextPreview, "Plain body")
    XCTAssertTrue(parsed.attachments.isEmpty)
  }

  func testMIMEParserFindsMultipartMixedAttachment() throws {
    let data = mimeMessage(
      headers: ["Content-Type: multipart/mixed; boundary=\"mix\""],
      body: """
        --mix
        Content-Type: text/plain; charset=utf-8

        Body text
        --mix
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="report.bin"
        Content-Transfer-Encoding: base64
        Content-ID: <part-1@example.test>

        AQIDBAU=
        --mix--

        """
    )

    let parsed = MIMEParser().parse(data)

    XCTAssertEqual(parsed.safePlainTextPreview, "Body text")
    XCTAssertEqual(parsed.attachments.map(\.metadata.filename), ["report.bin"])
    XCTAssertEqual(parsed.attachments.first?.metadata.mimeType, "application/octet-stream")
    XCTAssertEqual(parsed.attachments.first?.metadata.contentID, "part-1@example.test")
    XCTAssertEqual(parsed.attachments.first?.metadata.byteSize, 5)
    XCTAssertEqual(parsed.attachments.first?.decodedData, Data([1, 2, 3, 4, 5]))
  }

  func testMIMEParserHandlesNestedMultipart() throws {
    let data = mimeMessage(
      headers: ["Content-Type: multipart/mixed; boundary=\"outer\""],
      body: """
        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/html; charset=utf-8

        <p>Nested HTML</p>
        --inner
        Content-Type: text/plain; charset=utf-8

        Nested plain
        --inner--
        --outer--

        """
    )

    let parsed = MIMEParser().parse(data)

    XCTAssertEqual(parsed.safePlainTextPreview, "Nested plain")
  }

  func testMIMEParserHandlesMessageRFC822Part() throws {
    let data = mimeMessage(
      headers: ["Content-Type: message/rfc822"],
      body: """
        Subject: Attached message
        Content-Type: text/plain; charset=utf-8

        Forwarded body
        """
    )

    XCTAssertEqual(MIMEParser().parse(data).safePlainTextPreview, "Forwarded body")
  }

  func testMIMEParserDecodesBase64Body() throws {
    let data = mimeMessage(
      headers: [
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: base64",
      ],
      body: "QmFzZTY0IHRleHQ=\n"
    )

    XCTAssertEqual(MIMEParser().parse(data).safePlainTextPreview, "Base64 text")
  }

  func testMIMEParserDecodesQuotedPrintableBody() throws {
    let data = mimeMessage(
      headers: [
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: quoted-printable",
      ],
      body: "Hello=2C soft=\nline=21\n"
    )

    XCTAssertEqual(MIMEParser().parse(data).safePlainTextPreview, "Hello, softline!")
  }

  func testMIMEParserReturnsPartialResultForMalformedQuotedPrintable() throws {
    let data = mimeMessage(
      headers: [
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: quoted-printable",
      ],
      body: "Broken=XX text\n"
    )

    let parsed = MIMEParser().parse(data)

    XCTAssertEqual(parsed.safePlainTextPreview, "Broken=XX text")
    XCTAssertTrue(parsed.warnings.contains { $0.contains("malformed quoted-printable") })
  }

  func testMIMEParserDefaultsMissingCharsetToSafeText() throws {
    let data = mimeMessage(
      headers: ["Content-Type: text/plain"],
      body: "No charset body\n"
    )

    XCTAssertEqual(MIMEParser().parse(data).safePlainTextPreview, "No charset body")
  }

  func testMIMEParserDecodesISO88591Body() throws {
    var data = Data("Content-Type: text/plain; charset=iso-8859-1\n\n".utf8)
    data.append(contentsOf: [0x41, 0x6E, 0x64, 0x72, 0xE9])

    XCTAssertEqual(MIMEParser().parse(data).safePlainTextPreview, "André")
  }

  func testMIMEParserDecodesWindows1250Body() throws {
    var data = Data("Content-Type: text/plain; charset=windows-1250\n\n".utf8)
    data.append(contentsOf: [0x8E, 0x6C, 0x75, 0x9D])

    XCTAssertEqual(MIMEParser().parse(data).safePlainTextPreview, "Žluť")
  }

  func testMIMEParserReturnsPartialResultForMissingBoundaryTerminator() throws {
    let data = mimeMessage(
      headers: ["Content-Type: multipart/mixed; boundary=\"mix\""],
      body: """
        --mix
        Content-Type: text/plain; charset=utf-8

        Partial body

        """
    )

    let parsed = MIMEParser().parse(data)

    XCTAssertEqual(parsed.safePlainTextPreview, "Partial body")
    XCTAssertTrue(parsed.warnings.contains { $0.contains("missing a closing boundary") })
  }

  func testMIMEParserReturnsPartialResultForInvalidBase64() throws {
    let data = mimeMessage(
      headers: [
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: base64",
      ],
      body: "SGVsbG8*bad\n"
    )

    let parsed = MIMEParser().parse(data)

    XCTAssertEqual(parsed.safePlainTextPreview, "Hello")
    XCTAssertTrue(parsed.warnings.contains { $0.contains("invalid Base64") })
  }

  func testMIMEParserDecodesRFC2047Filename() throws {
    let data = mimeMessage(
      headers: ["Content-Type: multipart/mixed; boundary=\"mix\""],
      body: """
        --mix
        Content-Type: text/plain

        Body
        --mix
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="=?UTF-8?B?SmFuIEtvxI3DrS50eHQ=?="
        Content-Transfer-Encoding: base64

        QQ==
        --mix--

        """
    )

    XCTAssertEqual(
      MIMEParser().parse(data).attachments.first?.metadata.filename, "Jan Kočí.txt")
  }

  func testMIMEParserDecodesRFC2231Filename() throws {
    let data = mimeMessage(
      headers: ["Content-Type: multipart/mixed; boundary=\"mix\""],
      body: """
        --mix
        Content-Type: text/plain

        Body
        --mix
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*=UTF-8''Jan%20Ko%C4%8D%C3%AD.txt
        Content-Transfer-Encoding: base64

        QQ==
        --mix--

        """
    )

    XCTAssertEqual(
      MIMEParser().parse(data).attachments.first?.metadata.filename, "Jan Kočí.txt")
  }

  func testMIMEParserHandlesFoldedAndDuplicateMIMEHeaders() throws {
    let data = mimeMessage(
      headers: [
        "Content-Type: multipart/mixed;",
        " boundary=\"mix\"",
        "X-Duplicate: first",
        "X-Duplicate: second",
      ],
      body: """
        --mix
        Content-Type: text/plain; charset=utf-8

        Folded header body
        --mix--

        """
    )

    let parsed = MIMEParser().parse(data)

    XCTAssertEqual(parsed.safePlainTextPreview, "Folded header body")
    XCTAssertEqual(parsed.root.headers["X-Duplicate"], "first, second")
  }

  func testMIMEParserTreatsInlineNamedPartAsAttachment() throws {
    let data = mimeMessage(
      headers: ["Content-Type: multipart/related; boundary=\"rel\""],
      body: """
        --rel
        Content-Type: text/html; charset=utf-8

        <p>Related body</p>
        --rel
        Content-Type: application/octet-stream
        Content-Disposition: inline; filename="inline.bin"
        Content-Transfer-Encoding: base64
        Content-ID: <inline@example.test>

        AQI=
        --rel--

        """
    )

    let attachment = try XCTUnwrap(MIMEParser().parse(data).attachments.first?.metadata)

    XCTAssertEqual(attachment.filename, "inline.bin")
    XCTAssertEqual(attachment.disposition, "inline")
    XCTAssertEqual(attachment.contentID, "inline@example.test")
  }

  func testMIMEParserHTMLPreviewDoesNotExposeRemoteResourcesOrScripts() throws {
    let data = mimeMessage(
      headers: ["Content-Type: text/html; charset=utf-8"],
      body: """
        <html><body><p>Visible text</p><img src="https://tracking.example.test/pixel.png"><script>alert("x")</script></body></html>
        """
    )

    let preview = try XCTUnwrap(MIMEParser().parse(data).safePlainTextPreview)

    XCTAssertTrue(preview.contains("Visible text"))
    XCTAssertFalse(preview.contains("https://tracking.example.test"))
    XCTAssertFalse(preview.localizedCaseInsensitiveContains("script"))
    XCTAssertFalse(preview.contains("alert"))
  }

  func testMIMEParserAttachmentExtractionPreservesExactBytes() throws {
    let expected = Data([0x00, 0x7F, 0x80, 0xFF, 0x41, 0x42])
    let data = mimeMessage(
      headers: ["Content-Type: multipart/mixed; boundary=\"mix\""],
      body: """
        --mix
        Content-Type: text/plain

        Body
        --mix
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="bytes.bin"
        Content-Transfer-Encoding: base64

        AH+A/0FC
        --mix--

        """
    )
    let parsed = MIMEParser().parse(data)
    let id = try XCTUnwrap(parsed.attachments.first?.metadata.id)

    XCTAssertEqual(MIMEParser().decodedAttachmentData(id: id, from: data), expected)
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
    try "Subject: Missing delimiter\n\nBody\n".write(
      to: fileURL, atomically: true, encoding: .utf8)
    let descriptor = MailSourceDescriptor(
      name: "malformed.mbox", kind: .mbox, location: fileURL)

    do {
      _ = try await MailAnalyzer().analyze(source: descriptor)
      XCTFail("Expected malformed archive error.")
    } catch ConnectorError.malformedArchive {
      // Expected.
    } catch {
      XCTFail("Expected malformed archive error, got \(error).")
    }
  }

  func testSQLiteIndexCreatesSchemaAndPreservesDataAfterReopen() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("index.mbox")
    try writeMBOX(
      messages: [
        message(
          id: "invoice@example.test",
          subject: "Invoice from Apple",
          sender: "Apple Store <receipts@apple.example>",
          recipients: ["Jan <jan@example.test>"],
          date: "Thu, 15 Jun 2023 10:00:00 +0000",
          extraHeaders: [],
          body: "Invoice receipt for local indexing.\n"
        ),
        message(
          id: "newsletter@example.test",
          subject: "Weekly newsletter",
          sender: "News <news@example.test>",
          recipients: ["Archive <archive@example.test>"],
          date: "Thu, 20 Jul 2023 10:00:00 +0000",
          extraHeaders: ["List-Unsubscribe: <mailto:unsubscribe@example.test>"],
          body: "News update.\n"
        ),
      ],
      to: fileURL
    )
    let databaseURL = directory.appendingPathComponent("index.sqlite")
    let descriptor = MailSourceDescriptor(name: "index.mbox", kind: .mbox, location: fileURL)

    try await MailIndexingService().buildIndex(
      for: descriptor,
      store: try MailIndexStore(databaseURL: databaseURL),
      batchSize: 1
    )

    let reopened = try MailIndexStore(databaseURL: databaseURL)
    XCTAssertEqual(try reopened.schemaVersion(), MailIndexStore.currentSchemaVersion)
    let page = try reopened.search(
      sourceID: descriptor.id,
      query: try SearchQueryParser().parse("invoice"),
      limit: 20,
      offset: 0
    )

    XCTAssertEqual(page.totalCount, 1)
    XCTAssertEqual(page.messages.first?.subject, "Invoice from Apple")
    XCTAssertGreaterThan(
      try XCTUnwrap(try reopened.sourceMetadata(sourceID: descriptor.id)).databaseSize,
      0
    )
  }

  func testSQLiteIndexSearchFiltersAndPaging() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("filters.mbox")
    let duplicate = message(
      id: "duplicate@example.test",
      subject: "Duplicate invoice",
      sender: "Billing <billing@example.test>",
      recipients: ["Finance <finance@example.test>"],
      date: "Thu, 10 Aug 2023 10:00:00 +0000",
      extraHeaders: [],
      body: "Same invoice body.\n"
    )
    let largeBody = String(repeating: "Large local body ", count: 120) + "\n"
    try writeMBOX(
      messages: [
        message(
          id: "apple@example.test",
          subject: "Invoice from Apple",
          sender: "Apple <receipts@apple.example>",
          recipients: ["Finance <finance@example.test>"],
          date: "Thu, 15 Jun 2023 10:00:00 +0000",
          extraHeaders: [],
          body: "Invoice receipt searchable text.\n"
        ),
        message(
          id: "attachment@example.test",
          subject: "Report with attachment",
          sender: "Reports <reports@example.test>",
          recipients: ["Jan <jan@example.test>"],
          date: "Thu, 1 Feb 2024 10:00:00 +0000",
          extraHeaders: ["Content-Type: multipart/mixed; boundary=\"mix\""],
          body: """
            --mix
            Content-Type: text/plain

            Attached report body.
            --mix
            Content-Type: application/octet-stream
            Content-Disposition: attachment; filename="report.bin"
            Content-Transfer-Encoding: base64

            QQ==
            --mix--

            """
        ),
        message(
          id: "newsletter@example.test",
          subject: "Weekly newsletter",
          sender: "News <news@example.test>",
          recipients: ["Archive <archive@example.test>"],
          date: "Thu, 20 Jul 2023 10:00:00 +0000",
          extraHeaders: ["List-Unsubscribe: <mailto:unsubscribe@example.test>"],
          body: "News update.\n"
        ),
        message(
          id: "otp@example.test",
          subject: "Your OTP code",
          sender: "Auth <auth@example.test>",
          recipients: ["Security <security@example.test>"],
          date: "Thu, 5 Jan 2023 10:00:00 +0000",
          extraHeaders: [],
          body: "Use 123456.\n"
        ),
        message(
          id: "sensitive@example.test",
          subject: "Bank contract",
          sender: "Legal <legal@example.test>",
          recipients: ["Jan <jan@example.test>"],
          date: "Thu, 1 Mar 2024 10:00:00 +0000",
          extraHeaders: [],
          body: largeBody
        ),
        duplicate,
        duplicate,
      ],
      to: fileURL
    )

    let descriptor = MailSourceDescriptor(name: "filters.mbox", kind: .mbox, location: fileURL)
    let store = try MailIndexStore(databaseURL: directory.appendingPathComponent("filters.sqlite"))
    try await MailIndexingService().buildIndex(for: descriptor, store: store, batchSize: 2)
    let parser = SearchQueryParser()

    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("invoice"), limit: 20, offset: 0
      ).totalCount,
      3
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("from:apple"), limit: 20,
        offset: 0
      ).totalCount,
      1
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("to:finance"), limit: 20,
        offset: 0
      ).totalCount,
      3
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("has:attachment"), limit: 20,
        offset: 0
      ).totalCount,
      1
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("is:duplicate"), limit: 20,
        offset: 0
      ).totalCount,
      2
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("is:newsletter"), limit: 20,
        offset: 0
      ).totalCount,
      1
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("is:otp"), limit: 20, offset: 0
      ).totalCount,
      1
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("is:sensitive"), limit: 20,
        offset: 0
      ).totalCount,
      4
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("larger:1KB"), limit: 20,
        offset: 0
      ).totalCount,
      1
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("before:2024-01-01"), limit: 20,
        offset: 0
      ).totalCount,
      5
    )
    XCTAssertEqual(
      try store.search(
        sourceID: descriptor.id, query: try parser.parse("after:2023-01-01"), limit: 20,
        offset: 0
      ).totalCount,
      7
    )

    let firstPage = try store.search(sourceID: descriptor.id, query: .empty, limit: 2, offset: 0)
    let secondPage = try store.search(sourceID: descriptor.id, query: .empty, limit: 2, offset: 2)
    XCTAssertEqual(firstPage.messages.count, 2)
    XCTAssertEqual(secondPage.messages.count, 2)
    XCTAssertTrue(
      Set(firstPage.messages.map(\.sourceIdentifier)).isDisjoint(
        with: Set(secondPage.messages.map(\.sourceIdentifier))
      )
    )

    let senderAscending = try store.search(
      sourceID: descriptor.id,
      query: .empty,
      sort: .init(column: .sender, ascending: true),
      limit: 20,
      offset: 0
    )
    let senderDescending = try store.search(
      sourceID: descriptor.id,
      query: .empty,
      sort: .init(column: .sender, ascending: false),
      limit: 20,
      offset: 0
    )
    XCTAssertEqual(senderAscending.messages.first?.sender, "Apple <receipts@apple.example>")
    XCTAssertEqual(senderDescending.messages.first?.sender, "Reports <reports@example.test>")
  }

  func testSearchQueryParserRejectsInvalidFilters() {
    XCTAssertThrowsError(try SearchQueryParser().parse("is:unknown"))
    XCTAssertThrowsError(try SearchQueryParser().parse("before:2024-99-99"))
    XCTAssertThrowsError(try SearchQueryParser().parse("larger:huge"))
  }

  func testSQLInjectionLikeSearchInputIsHarmless() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("injection.mbox")
    try writeMBOX(
      messages: [
        message(
          id: "safe@example.test",
          subject: "Safe invoice",
          extraHeaders: [],
          body: "Local only.\n"
        )
      ],
      to: fileURL
    )
    let descriptor = MailSourceDescriptor(name: "injection.mbox", kind: .mbox, location: fileURL)
    let store = try MailIndexStore(
      databaseURL: directory.appendingPathComponent("injection.sqlite"))
    try await MailIndexingService().buildIndex(for: descriptor, store: store)

    _ = try store.search(
      sourceID: descriptor.id,
      query: try SearchQueryParser().parse("invoice'); DROP TABLE messages; --"),
      limit: 20,
      offset: 0
    )
    let page = try store.search(
      sourceID: descriptor.id,
      query: try SearchQueryParser().parse("invoice"),
      limit: 20,
      offset: 0
    )
    XCTAssertEqual(page.totalCount, 1)
  }

  func testInterruptedIndexStateAndStaleSourceDetection() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("state.mbox")
    try writeMBOX(
      messages: [
        message(id: "state@example.test", subject: "State", extraHeaders: [], body: "Body\n")
      ],
      to: fileURL
    )
    let descriptor = MailSourceDescriptor(name: "state.mbox", kind: .mbox, location: fileURL)
    let store = try MailIndexStore(databaseURL: directory.appendingPathComponent("state.sqlite"))
    let fingerprint = try MailIndexingService.fingerprint(for: descriptor)

    try store.beginIndexing(source: descriptor, fingerprint: fingerprint)
    XCTAssertEqual(
      try store.status(source: descriptor, currentFingerprint: fingerprint).status,
      .indexing
    )

    try await MailIndexingService().buildIndex(for: descriptor, store: store)
    XCTAssertEqual(
      try store.status(
        source: descriptor,
        currentFingerprint: try MailIndexingService.fingerprint(for: descriptor)
      ).status,
      .indexed
    )

    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    handle.write(
      Data(
        "From later@example.test Thu Jan 01 00:00:00 2026\nSubject: Later\n\nBody\n".utf8))
    XCTAssertEqual(
      try store.status(
        source: descriptor,
        currentFingerprint: try MailIndexingService.fingerprint(for: descriptor)
      ).status,
      .stale
    )
  }

  func testIndexDeletionDoesNotTouchSourceMBOX() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("delete.mbox")
    try writeMBOX(
      messages: [
        message(
          id: "delete@example.test",
          subject: "Delete index only",
          extraHeaders: [],
          body: "Mailbox must remain.\n"
        )
      ],
      to: fileURL
    )
    let originalData = try Data(contentsOf: fileURL)
    let descriptor = MailSourceDescriptor(name: "delete.mbox", kind: .mbox, location: fileURL)
    let store = try MailIndexStore(databaseURL: directory.appendingPathComponent("delete.sqlite"))

    try await MailIndexingService().buildIndex(for: descriptor, store: store)
    try store.deleteIndex(for: descriptor.id)

    XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    XCTAssertEqual(
      try store.status(source: descriptor, currentFingerprint: nil).status,
      .notIndexed
    )
  }

  func testRecoveryScannerDetectsRequiredSyntheticIssues() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("recovery.mbox")
    let duplicate = rawMessage(
      [
        "Message-ID: <dup@example.test>",
        "Subject: Duplicate",
        "From: Sender <sender@example.test>",
        "To: Recipient <recipient@example.test>",
        "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        "Content-Type: text/plain; charset=utf-8",
      ],
      body: "Same body\n"
    )
    let multipartUnterminated = rawMessage(
      [
        "Message-ID: <mime@example.test>",
        "Subject: MIME",
        "From: Sender <sender@example.test>",
        "To: Recipient <recipient@example.test>",
        "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        "Content-Type: multipart/mixed; boundary=\"mix\"",
      ],
      body: """
        --mix
        Content-Type: text/plain; charset=x-unknown
        Content-Transfer-Encoding: quoted-printable

        Broken=XX text
        --mix
        Content-Type: application/octet-stream; name="../evil.bin"
        Content-Disposition: attachment; filename="../evil.bin"
        Content-Transfer-Encoding: base64
        Content-ID: <dup-cid@example.test>

        SGVsbG8*bad
        --mix
        Content-Type: application/octet-stream
        Content-Disposition: inline
        Content-Transfer-Encoding: base64
        Content-ID: <dup-cid@example.test>


        """
    )
    let htmlCID = rawMessage(
      [
        "Message-ID: <html@example.test>",
        "Subject: HTML",
        "From: Sender <sender@example.test>",
        "To: Recipient <recipient@example.test>",
        "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        "Content-Type: text/plain; charset=utf-8",
      ],
      body: "<html><body><img src=\"cid:missing@example.test\"></body></html>\n"
    )
    let zeroAttachment = rawMessage(
      [
        "Message-ID: <zero@example.test>",
        "Subject: Zero Attachment",
        "From: Sender <sender@example.test>",
        "To: Recipient <recipient@example.test>",
        "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        "Content-Type: multipart/mixed; boundary=\"zero\"",
      ],
      body: """
        --zero
        Content-Type: text/plain

        Body
        --zero
        Content-Type: application/octet-stream
        Content-Disposition: attachment
        Content-Transfer-Encoding: base64


        --zero--

        """
    )
    let messages = [
      rawMessage(
        [
          "Subject: Missing ID",
          "From: Sender <sender@example.test>",
          "To: Recipient <recipient@example.test>",
          "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        ],
        body: "No ID\n"
      ),
      rawMessage(
        [
          "Message-ID: malformed",
          "Subject: Bad ID",
          "From: Sender <sender@example.test>",
          "To: Recipient <recipient@example.test>",
          "Date: not a date",
          "Content-Type: multipart/mixed",
        ],
        body: "From body line\n"
      ),
      rawMessage(
        [
          "Message-ID: <missing-from@example.test>",
          "Subject: Missing From",
          "To: Recipient <recipient@example.test>",
          "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        ],
        body: "Body\n"
      ),
      rawMessage(
        [
          "Message-ID: <missing-to@example.test>",
          "Subject: Missing To",
          "From: Sender <sender@example.test>",
          "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        ],
        body: "Body\n"
      ),
      "Message-ID: <unterminated@example.test>\nSubject: No terminator\nFrom: Sender <sender@example.test>\nTo: Recipient <recipient@example.test>\nDate: Thu, 1 Jan 2026 00:00:00 +0000\n",
      " Bad folded\nMessage-ID: <folded@example.test>\nBad Header\nSubject: Folded\nFrom: Sender <sender@example.test>\nTo: Recipient <recipient@example.test>\nDate: Thu, 1 Jan 2026 00:00:00 +0000\n\nBody\n",
      rawMessage(
        [
          "Message-ID: <binary@example.test>",
          "Subject: Binary",
          "From: Sender <sender@example.test>\u{0001}",
          "To: Recipient <recipient@example.test>",
          "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        ],
        body: "Body\n"
      ),
      rawMessage(
        [
          "Message-ID: <unknown-encoding@example.test>",
          "Subject: Encoding",
          "From: Sender <sender@example.test>",
          "To: Recipient <recipient@example.test>",
          "Date: Thu, 1 Jan 2026 00:00:00 +0000",
          "Content-Type: text/plain; charset=x-unknown",
          "Content-Transfer-Encoding: x-custom",
        ],
        body: "Body\n"
      ),
      duplicate,
      duplicate,
      rawMessage(
        [
          "Message-ID: <dup@example.test>",
          "Subject: Duplicate Different",
          "From: Sender <sender@example.test>",
          "To: Recipient <recipient@example.test>",
          "Date: Thu, 1 Jan 2026 00:00:00 +0000",
        ],
        body: "Different body\n"
      ),
      multipartUnterminated,
      htmlCID,
      zeroAttachment,
    ]
    try writeMBOX(messages: messages, to: fileURL)

    let report = try await RecoveryScanner().scan(
      source: MailSourceDescriptor(name: "recovery.mbox", kind: .mbox, location: fileURL)
    )
    let kinds = Set(report.issues.map(\.kind))

    XCTAssertTrue(kinds.contains(.missingMessageID))
    XCTAssertTrue(kinds.contains(.malformedMessageID))
    XCTAssertTrue(kinds.contains(.duplicateMessageID))
    XCTAssertTrue(kinds.contains(.sameMessageIDDifferentHash))
    XCTAssertTrue(kinds.contains(.invalidDateHeader))
    XCTAssertTrue(kinds.contains(.missingFromHeader))
    XCTAssertTrue(kinds.contains(.missingRecipientHeaders))
    XCTAssertTrue(kinds.contains(.missingHeaderTerminator))
    XCTAssertTrue(kinds.contains(.foldedHeaderWithoutParent))
    XCTAssertTrue(kinds.contains(.malformedHeader))
    XCTAssertTrue(kinds.contains(.binaryBytesInHeaders))
    XCTAssertTrue(kinds.contains(.missingMultipartBoundary))
    XCTAssertTrue(kinds.contains(.unterminatedMultipartBoundary))
    XCTAssertTrue(kinds.contains(.invalidBase64))
    XCTAssertTrue(kinds.contains(.malformedQuotedPrintable))
    XCTAssertTrue(kinds.contains(.unknownTransferEncoding))
    XCTAssertTrue(kinds.contains(.invalidOrUnknownCharset))
    XCTAssertTrue(kinds.contains(.missingContentType))
    XCTAssertTrue(kinds.contains(.contradictoryContentTypeAndBody))
    XCTAssertTrue(kinds.contains(.attachmentMissingFilename))
    XCTAssertTrue(kinds.contains(.unsafeAttachmentFilename))
    XCTAssertTrue(kinds.contains(.duplicateContentID))
    XCTAssertTrue(kinds.contains(.referencedInlineContentIDNotFound))
    XCTAssertTrue(kinds.contains(.zeroByteAttachment))
    XCTAssertTrue(kinds.contains(.exactDuplicateMessageHash))
    XCTAssertEqual(report.estimatedRemovedDuplicateCount, 1)
    XCTAssertGreaterThan(report.suggestions.count, 0)
  }

  func testRecoveryScannerDetectsMalformedMBOXAndTruncatedFinalMessage() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("truncated.mbox")
    let content = """
      From bad separator
      From sender@example.test Thu Jan 01 00:00:00 2026
      Message-ID: <truncated@example.test>
      Subject: Truncated
      From: Sender <sender@example.test>
      To: Recipient <recipient@example.test>
      Date: Thu, 1 Jan 2026 00:00:00 +0000

      Body without final newline
      """
    try content.write(to: fileURL, atomically: true, encoding: .utf8)

    let report = try await RecoveryScanner().scan(
      source: MailSourceDescriptor(name: "truncated.mbox", kind: .mbox, location: fileURL)
    )
    let kinds = Set(report.issues.map(\.kind))

    XCTAssertTrue(kinds.contains(.malformedFromSeparator))
    XCTAssertTrue(kinds.contains(.truncatedFinalMessage))
  }

  func testRecoveryReportJSONAndMarkdownDoNotContainBodiesByDefault() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("report.mbox")
    try writeMBOX(
      messages: [
        rawMessage(
          ["Subject: Missing", "From: Sender <sender@example.test>", "Date: bad"],
          body: "PRIVATE BODY SHOULD NOT EXPORT\n"
        )
      ],
      to: fileURL
    )

    let report = try await RecoveryScanner().scan(
      source: MailSourceDescriptor(name: "report.mbox", kind: .mbox, location: fileURL)
    )
    let json = String(data: try report.jsonData(), encoding: .utf8) ?? ""
    let markdown = report.markdown()

    XCTAssertFalse(json.contains("PRIVATE BODY SHOULD NOT EXPORT"))
    XCTAssertFalse(markdown.contains("PRIVATE BODY SHOULD NOT EXPORT"))
    XCTAssertTrue(markdown.contains("Mail Surgeon Recovery Report"))
  }

  func testRecoveryExportDeduplicatesEscapesAndKeepsSourceByteIdentical() async throws {
    let directory = try makeTemporaryDirectory()
    let safeDirectory = try makeSafeOutputDirectory()
    let sourceURL = directory.appendingPathComponent("export.mbox")
    let duplicate = message(
      id: "duplicate@example.test",
      subject: "Duplicate",
      extraHeaders: [],
      body: "From body@example.test is not a delimiter\nBody\n"
    )
    try writeMBOX(messages: [duplicate, duplicate], to: sourceURL)
    let original = try Data(contentsOf: sourceURL)
    let source = MailSourceDescriptor(name: "export.mbox", kind: .mbox, location: sourceURL)
    let report = try await RecoveryScanner().scan(source: source)
    let destination = safeDirectory.appendingPathComponent("deduped.mbox")

    let result = try await RecoveryExportService().export(
      source: source,
      report: report,
      mode: .deduplicated,
      destination: destination
    )

    let output = try String(contentsOf: destination, encoding: .utf8)
    XCTAssertEqual(result.exportedMessageCount, 1)
    XCTAssertEqual(result.excludedDuplicateCount, 1)
    XCTAssertTrue(output.contains(">From body@example.test is not a delimiter"))
    XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.reportURL.path))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: safeDirectory.path).contains {
        $0.contains(".tmp-")
      }
    )
  }

  func testRecoveryExportQuarantinesCriticalMessages() async throws {
    let directory = try makeTemporaryDirectory()
    let safeDirectory = try makeSafeOutputDirectory()
    let sourceURL = directory.appendingPathComponent("quarantine.mbox")
    try writeMBOX(
      messages: [
        "",
        message(id: "good@example.test", subject: "Good", extraHeaders: [], body: "Body\n"),
      ],
      to: sourceURL
    )
    let source = MailSourceDescriptor(name: "quarantine.mbox", kind: .mbox, location: sourceURL)
    let report = try await RecoveryScanner().scan(source: source)
    let destination = safeDirectory.appendingPathComponent("recoverable.mbox")

    let result = try await RecoveryExportService().export(
      source: source,
      report: report,
      mode: .recoverableOnly,
      destination: destination
    )

    XCTAssertEqual(result.quarantinedMessageCount, 1)
    XCTAssertEqual(result.exportedMessageCount, 1)
    XCTAssertNotNil(result.quarantineURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
  }

  func testRecoveryExportRejectsDestinationEqualToSource() async throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("same.mbox")
    try writeMBOX(
      messages: [
        message(id: "same@example.test", subject: "Same", extraHeaders: [], body: "Body\n")
      ],
      to: sourceURL
    )
    let source = MailSourceDescriptor(name: "same.mbox", kind: .mbox, location: sourceURL)
    let report = try await RecoveryScanner().scan(source: source)

    do {
      _ = try await RecoveryExportService().export(
        source: source,
        report: report,
        mode: .preserveAll,
        destination: sourceURL
      )
      XCTFail("Expected source/destination rejection.")
    } catch RecoveryError.sourceAndDestinationMatch {
      // Expected.
    } catch {
      XCTFail("Expected sourceAndDestinationMatch, got \(error).")
    }
  }

  func testRecoveryPersistenceReopenAndFingerprintInvalidation() async throws {
    let directory = try makeTemporaryDirectory()
    let fileURL = directory.appendingPathComponent("persist.mbox")
    try writeMBOX(
      messages: [
        rawMessage(
          ["Subject: Missing", "From: Sender <sender@example.test>", "Date: bad"],
          body: "Body\n"
        )
      ],
      to: fileURL
    )
    let source = MailSourceDescriptor(name: "persist.mbox", kind: .mbox, location: fileURL)
    let report = try await RecoveryScanner().scan(source: source)
    let databaseURL = directory.appendingPathComponent("recovery.sqlite")

    try MailIndexStore(databaseURL: databaseURL).saveRecoveryReport(report)
    let reopened = try MailIndexStore(databaseURL: databaseURL)
    XCTAssertEqual(try reopened.schemaVersion(), MailIndexStore.currentSchemaVersion)
    let current = try MailIndexingService.fingerprint(for: source)
    XCTAssertEqual(
      try reopened.latestRecoveryReport(sourceID: source.id, currentFingerprint: current)?.id,
      report.id
    )

    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    handle.write(Data("changed\n".utf8))
    XCTAssertNil(
      try reopened.latestRecoveryReport(
        sourceID: source.id,
        currentFingerprint: try MailIndexingService.fingerprint(for: source)
      )
    )
  }

  func testRecoveryExportCancellationCleansTemporaryOutput() async throws {
    let directory = try makeTemporaryDirectory()
    let safeDirectory = try makeSafeOutputDirectory()
    let sourceURL = directory.appendingPathComponent("cancel.mbox")
    let messages = (0..<2_000).map {
      message(
        id: "cancel-\($0)@example.test", subject: "Cancel \($0)", extraHeaders: [], body: "Body\n")
    }
    try writeMBOX(messages: messages, to: sourceURL)
    let source = MailSourceDescriptor(name: "cancel.mbox", kind: .mbox, location: sourceURL)
    let report = try await RecoveryScanner().scan(source: source)
    let destination = safeDirectory.appendingPathComponent("cancel-output.mbox")

    let task = Task {
      try await RecoveryExportService().export(
        source: source,
        report: report,
        mode: .preserveAll,
        destination: destination
      )
    }
    task.cancel()
    do {
      _ = try await task.value
    } catch is CancellationError {
      // Expected.
    } catch {
      // Fast machines may complete before cancellation; other errors should still fail.
      XCTFail("Unexpected cancellation error: \(error)")
    }

    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: safeDirectory.path).contains {
        $0.contains(".tmp-")
      }
    )
  }

  @MainActor
  func testExportCommandStateValidationAndCancelledSavePanel() {
    let panel = FakeSavePanelProvider()
    let model = AppModel(savePanelProvider: panel)
    model.sources = []
    model.selectedSourceID = nil

    XCTAssertFalse(model.canExportRecoveryReport)
    XCTAssertFalse(model.canExportRecoveryMBOX)

    let source = MailSourceDescriptor(
      name: "cancel.mbox",
      kind: .mbox,
      location: URL(fileURLWithPath: "/tmp/cancel.mbox")
    )
    model.sources = [source]
    model.selectedSourceID = source.id
    model.recoveryReport = recoveryReport(source: source)

    XCTAssertTrue(model.canExportRecoveryReport)
    XCTAssertTrue(model.canExportRecoveryMBOX)

    model.exportRecoveryReportJSON()

    XCTAssertEqual(panel.commands, [.recoveryReportJSON])
    XCTAssertNil(model.recoveryErrorMessage)
    XCTAssertFalse(model.statusMessage.contains("selhal"))
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

  private func rawMessage(_ headers: [String], body: String) -> String {
    headers.joined(separator: "\n") + "\n\n" + body
  }

  private func makeSafeOutputDirectory() throws -> URL {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(".build")
      .appendingPathComponent("recovery-test-output")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func message(
    id: String,
    subject: String,
    sender: String = "Sender <sender@example.test>",
    recipients: [String] = ["Recipient <recipient@example.test>"],
    date: String = "Thu, 1 Jan 2026 00:00:00 +0000",
    extraHeaders: [String],
    body: String
  )
    -> String
  {
    var headers = [
      "Message-ID: <\(id)>",
      "Subject: \(subject)",
      "From: \(sender)",
      "To: \(recipients.joined(separator: ", "))",
      "Date: \(date)",
    ]
    headers.append(contentsOf: extraHeaders)
    return headers.joined(separator: "\n") + "\n\n" + body
  }

  private func mimeMessage(headers: [String], body: String) -> Data {
    Data((headers.joined(separator: "\n") + "\n\n" + body).utf8)
  }

  private func scan(_ fileURL: URL) async throws -> [MailMessageRecord] {
    let descriptor = MailSourceDescriptor(
      name: fileURL.lastPathComponent, kind: .mbox, location: fileURL)
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

  private func recoveryReport(source: MailSourceDescriptor) -> RecoveryReport {
    RecoveryReport(
      id: UUID(),
      sourceID: source.id,
      sourceName: source.name,
      sourceFingerprint: SourceFingerprint(
        fileSize: 0,
        modificationDate: nil,
        lightweightHash: "test"
      ),
      scannerVersion: "test",
      startedAt: Date(timeIntervalSince1970: 0),
      completedAt: Date(timeIntervalSince1970: 1),
      totalMessagesScanned: 0,
      totalBytesScanned: 0,
      issues: [],
      suggestions: [],
      estimatedOutputMessageCount: 0,
      estimatedRemovedDuplicateCount: 0,
      estimatedQuarantinedMessageCount: 0,
      estimatedOutputByteSize: 0,
      privacyIncludesSubjectsSendersAndMessageIDs: false
    )
  }

  @MainActor
  private final class FakeSavePanelProvider: SavePanelProviding {
    var commands: [SavePanelCommand] = []
    var destinations: [SavePanelCommand: URL] = [:]

    func destination(for command: SavePanelCommand) -> URL? {
      commands.append(command)
      return destinations[command]
    }
  }
}
