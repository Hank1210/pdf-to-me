import DocKit
import PDFKit
import XCTest
@testable import PDFToMeCore

final class SplitRangeParsingTests: XCTestCase {
    private func parse(_ text: String, pages: Int = 9) throws -> [String] {
        try Splitter.parts(fromRanges: text, pageCount: pages).map(\.label)
    }

    private func assertFails(_ text: String, pages: Int = 9, _ expected: SplitError,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text, pages: pages), file: file, line: line) {
            XCTAssertEqual($0 as? SplitError, expected, file: file, line: line)
        }
    }

    func testRangesAndSinglePages() throws {
        XCTAssertEqual(try parse("1–3, 4–9"), ["1–3", "4–9"])
        XCTAssertEqual(try parse("1-3;5;7 - 8"), ["1–3", "5", "7–8"])
        XCTAssertEqual(try parse(" 2—4 ,, 6 "), ["2–4", "6"])
        XCTAssertEqual(try parse("3-3"), ["3"])
    }

    func testOpenRangeRunsToEnd() throws {
        XCTAssertEqual(try parse("1-4, 5-"), ["1–4", "5–9"])
        XCTAssertEqual(try parse("9–"), ["9"])
    }

    /// Überschneidungen sind erlaubt; jede Angabe ergibt eine Datei.
    func testOverlapsAndOrderAreKept() throws {
        XCTAssertEqual(try parse("5-9, 1-6"), ["5–9", "1–6"])
    }

    func testInvalidInput() {
        assertFails("", .noRanges)
        assertFails(" , ;", .noRanges)
        assertFails("a", .invalidEntry("a"))
        assertFails("1 3", .invalidEntry("1 3"))
        assertFails("-3", .invalidEntry("-3"))
        assertFails("1-3-5", .invalidEntry("1-3-5"))
        assertFails("1.5", .invalidEntry("1.5"))
        assertFails("5-2", .reversedRange("5-2"))
        assertFails("0-2", .outOfRange("0-2", pageCount: 9))
        assertFails("8-10", .outOfRange("8-10", pageCount: 9))
        assertFails("1-3, 12", .outOfRange("12", pageCount: 9))
    }

    func testEveryNPages() throws {
        XCTAssertEqual(try Splitter.parts(every: 3, pageCount: 9).map(\.label), ["1–3", "4–6", "7–9"])
        XCTAssertEqual(try Splitter.parts(every: 4, pageCount: 9).map(\.label), ["1–4", "5–8", "9"])
        XCTAssertEqual(try Splitter.parts(every: 1, pageCount: 3).map(\.label), ["1", "2", "3"])
        XCTAssertEqual(try Splitter.parts(every: 20, pageCount: 3).map(\.label), ["1–3"])
        XCTAssertThrowsError(try Splitter.parts(every: 0, pageCount: 3)) {
            XCTAssertEqual($0 as? SplitError, .invalidPartSize)
        }
        XCTAssertThrowsError(try Splitter.parts(every: 2, pageCount: 0))
    }

    func testMessagesNameTheEntry() {
        Localization.current = .en
        defer { Localization.current = .de }
        XCTAssertEqual(SplitError.outOfRange("8-10", pageCount: 9).errorDescription,
                       "“8-10” is outside the document (pages 1–9).")
        Localization.current = .de
        XCTAssertEqual(SplitError.reversedRange("5-2").errorDescription,
                       "Im Bereich „5-2“ ist die erste Seite größer als die letzte.")
    }

    func testStem() {
        XCTAssertEqual(Splitter.stem(forOriginal: "Contract.pdf"), "Contract")
        XCTAssertEqual(Splitter.stem(forOriginal: "Vertrag (bearbeitet) 2.pdf"), "Vertrag")
    }
}

final class SplitterSaveTests: XCTestCase {
    private var corpus: TestCorpus!
    private var plan: DocumentPlan!
    private var contents: SourceContents = [:]
    private var output: URL!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
        output = corpus.url("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    private func load(_ url: URL, password: String? = nil) throws {
        let loaded = try SourceLoader.load(url, password: password)
        contents[loaded.source.id] = loaded.content
        plan = try DocumentPlan(source: loaded.source)
    }

    private func texts(_ url: URL, password: String? = nil) throws -> [String] {
        let document = try XCTUnwrap(PDFDocument(url: url))
        if let password { XCTAssertTrue(document.unlock(withPassword: password)) }
        return (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func split(
        _ parts: [SplitPart], writer: any PDFWriting = QPDFKitWriter(), options: WriteOptions = WriteOptions()
    ) -> [Splitter.PartResult] {
        Splitter.save(
            plan, contents: contents, parts: parts, in: output, stem: "Contract",
            pipeline: SavePipeline(writer: writer), options: options)
    }

    func testSplitByRanges() throws {
        let original = try corpus.pdf(named: "Contract", pages: 9)
        let bytes = try Data(contentsOf: original)
        try load(original)

        let results = split(try Splitter.parts(fromRanges: "1–3, 4–9", pageCount: 9))
        let urls = try results.map { try $0.result.get().url }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Contract (1–3).pdf", "Contract (4–9).pdf"])
        XCTAssertEqual(try texts(urls[0]), (1...3).map { "Contract page \($0)" })
        XCTAssertEqual(try texts(urls[1]), (4...9).map { "Contract page \($0)" })
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    /// Die Angaben beziehen sich auf die aktuelle Reihenfolge, mit Drehung.
    func testSplitFollowsCurrentOrderAndRotation() throws {
        try load(corpus.pdf(named: "Contract", pages: 4))
        try plan.move([plan.pages[3].id], to: 0)            // 4, 1, 2, 3
        try plan.rotate([plan.pages[0].id], by: .quarter)

        let results = split(try Splitter.parts(every: 2, pageCount: 4))
        let urls = try results.map { try $0.result.get().url }
        XCTAssertEqual(try texts(urls[0]), ["Contract page 4", "Contract page 1"])
        XCTAssertEqual(try texts(urls[1]), ["Contract page 2", "Contract page 3"])
        XCTAssertEqual(PDFDocument(url: urls[0])?.page(at: 0)?.rotation, 90)
    }

    func testExistingNamesAreNotOverwritten() throws {
        try load(corpus.pdf(named: "Contract", pages: 2))
        let taken = output.appendingPathComponent("Contract (1).pdf")
        try Data("keep".utf8).write(to: taken)
        let results = split([SplitPart(first: 1, last: 1), SplitPart(first: 2, last: 2)])
        XCTAssertEqual(try results.map { try $0.result.get().url.lastPathComponent },
                       ["Contract (1) 2.pdf", "Contract (2).pdf"])
        XCTAssertEqual(try Data(contentsOf: taken), Data("keep".utf8))
    }

    func testLinksAndOutlineInsideAPart() throws {
        try load(corpus.linkedPDF(named: "Contract"))
        let results = split([SplitPart(first: 1, last: 3), SplitPart(first: 1, last: 2)])
        let whole = try XCTUnwrap(PDFDocument(url: try results[0].result.get().url))
        XCTAssertEqual(whole.outlineRoot?.numberOfChildren, 3)
        XCTAssertEqual(whole.page(at: 0)?.annotations.filter { $0.type == "Link" }.count, 1)

        // Ohne Seite 3 entfällt der Link dorthin und sein Eintrag im Inhaltsverzeichnis.
        let part = try XCTUnwrap(PDFDocument(url: try results[1].result.get().url))
        XCTAssertEqual(part.outlineRoot?.numberOfChildren, 2)
        XCTAssertEqual(part.page(at: 0)?.annotations.filter { $0.type == "Link" }.count, 0)
    }

    func testProtectedParts() throws {
        try load(corpus.encryptedPDF(password: "test-password"), password: "test-password")
        let options = WriteOptions(password: ProtectionSuggestion(for: plan)?.password)
        let results = split([SplitPart(first: 1, last: 1), SplitPart(first: 2, last: 2)], options: options)
        for result in results {
            let url = try result.result.get().url
            XCTAssertTrue(PDFDocument(url: url)?.isLocked == true)
            XCTAssertEqual(try texts(url, password: "test-password").count, 1)
        }
    }

    /// Schlägt ein Teil fehl, werden die anderen trotzdem gespeichert und der fehlerhafte gemeldet.
    func testFailingPartDoesNotStopOthers() throws {
        try load(corpus.pdf(named: "Contract", pages: 3))
        let results = split([
            SplitPart(first: 1, last: 1), SplitPart(first: 2, last: 5), SplitPart(first: 3, last: 3),
        ])
        XCTAssertEqual(try results[0].result.get().url.lastPathComponent, "Contract (1).pdf")
        XCTAssertThrowsError(try results[1].result.get()) {
            XCTAssertEqual($0 as? SplitError, .outOfRange("2–5", pageCount: 3))
        }
        XCTAssertEqual(try results[2].result.get().url.lastPathComponent, "Contract (3).pdf")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(),
                       ["Contract (1).pdf", "Contract (3).pdf"])
    }

    /// Ein Teil, der die Prüfung nicht besteht, landet nicht am Ziel; die übrigen schon.
    func testPartFailingVerification() throws {
        try load(corpus.pdf(named: "Contract", pages: 4))
        let failing = plan.pages[2].id
        let results = split(
            [SplitPart(first: 1, last: 2), SplitPart(first: 3, last: 4)],
            writer: FailingForPageWriter(pageID: failing, plan: plan))
        XCTAssertNoThrow(try results[0].result.get())
        XCTAssertThrowsError(try results[1].result.get()) {
            guard case .verificationFailed? = $0 as? SaveError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["Contract (1–2).pdf"])
    }
}

/// Schreibt Unsinn, sobald der Teil eine bestimmte Seite des Ausgangsplans enthält.
private struct FailingForPageWriter: PDFWriting {
    let capabilities: WriterCapabilities = [.pageOperations]
    let source: SourceFile.ID
    let index: Int

    init(pageID: PageRef.ID, plan: DocumentPlan) {
        let page = plan.page(withID: pageID)!
        (source, index) = (page.source, page.index)
    }

    func compose(_ plan: DocumentPlan, contents: SourceContents, to url: URL, options: WriteOptions) throws {
        if plan.pages.contains(where: { $0.source == source && $0.index == index }) {
            try Data("garbage".utf8).write(to: url)
        } else {
            try QPDFKitWriter().compose(plan, contents: contents, to: url, options: options)
        }
    }
}
