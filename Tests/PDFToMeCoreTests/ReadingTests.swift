import PDFKit
import XCTest
@testable import PDFToMeCore

final class ReadingTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    // MARK: Suche

    func testSearchGroupsMatchesByPage() throws {
        let document = try XCTUnwrap(PDFDocument(url: corpus.pdf(named: "Contract", pages: 12)))
        let results = DocumentSearch.search("page 1", in: document)
        // „page 1“ steht auf Seite 1, 10, 11 und 12 („page 10“ …).
        XCTAssertEqual(results.map(\.pageIndex), [0, 9, 10, 11])
        XCTAssertEqual(DocumentSearch.count(results), 4)
        XCTAssertEqual(results[0].matches[0].pageIndex, 0)
        XCTAssertTrue(results[0].matches[0].snippet.contains("Contract page 1"), results[0].matches[0].snippet)
    }

    func testSearchIgnoresCaseAndAccents() throws {
        let document = try XCTUnwrap(PDFDocument(url: corpus.mixedScriptPDF()))
        XCTAssertEqual(DocumentSearch.count(DocumentSearch.search("GRUSSE", in: document)), 1)   // ß = ss
        XCTAssertEqual(DocumentSearch.count(DocumentSearch.search("grüße", in: document)), 1)
        XCTAssertEqual(DocumentSearch.count(DocumentSearch.search("koln", in: document)), 1)
        XCTAssertEqual(DocumentSearch.count(DocumentSearch.search("OFFICE", in: document)), 1)
    }

    func testEmptyOrMissingQuery() throws {
        let document = try XCTUnwrap(PDFDocument(url: corpus.pdf(named: "A", pages: 2)))
        XCTAssertTrue(DocumentSearch.search("", in: document).isEmpty)
        XCTAssertTrue(DocumentSearch.search("   ", in: document).isEmpty)
        XCTAssertTrue(DocumentSearch.search("nowhere", in: document).isEmpty)
    }

    /// Gesucht wird in der Vorschau, also in der aktuellen Reihenfolge.
    func testSearchFollowsPlanOrder() throws {
        let document = try WorkingDocument(opening: corpus.pdf(named: "A", pages: 3), sessionStore: nil)
        try document.change { try $0.move([$0.pages[2].id], to: 0) }
        XCTAssertEqual(DocumentSearch.search("A page 3", in: document.preview.document).map(\.pageIndex), [0])
    }

    // MARK: Inhaltsverzeichnis

    func testOutlineEntries() throws {
        let document = try XCTUnwrap(PDFDocument(url: corpus.linkedPDF()))
        let entries = OutlineEntry.entries(of: document)
        XCTAssertEqual(entries.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(entries.map(\.pageIndex), [0, 1, 2])
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        XCTAssertTrue(entries.allSatisfy { $0.children == nil })
    }

    func testNestedOutlineFromMergedDocument() throws {
        let document = try WorkingDocument(opening: corpus.linkedPDF(named: "First"), sessionStore: nil)
        let second = try SourceLoader.load(corpus.linkedPDF(named: "Second"))
        try document.add([second]) { try $0.insertPages(of: second.source, at: 3) }

        let entries = OutlineEntry.entries(of: document.preview.document)
        XCTAssertEqual(entries.map(\.title), ["First.pdf", "Second.pdf"])
        XCTAssertEqual(entries[1].pageIndex, 3)
        XCTAssertEqual(entries[1].children?.map(\.pageIndex), [3, 4, 5])
        let ids = entries.flatMap { [$0.id] + ($0.children?.map(\.id) ?? []) }
        XCTAssertEqual(Set(ids).count, 8)
    }

    func testNoOutline() throws {
        let document = try XCTUnwrap(PDFDocument(url: corpus.pdf(named: "A", pages: 1)))
        XCTAssertEqual(OutlineEntry.entries(of: document), [])
    }
}

final class WorkingDocumentTests: XCTestCase {
    private var corpus: TestCorpus!
    private var store: SessionStore!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
        store = SessionStore(directory: corpus.url("Sessions"))
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    func testOpenBuildsPreview() throws {
        let document = try WorkingDocument(opening: corpus.pdf(named: "Contract", pages: 3), sessionStore: store)
        XCTAssertEqual(document.displayName, "Contract.pdf")
        XCTAssertEqual(document.preview.document.pageCount, 3)
        XCTAssertEqual(document.preview.pageIDs, document.plan.pages.map(\.id))
        // Nur geöffnet, nichts geändert: keine Sitzung nötig.
        XCTAssertEqual(try store.loadAll().sessions.count, 0)
    }

    func testOpenProtectedNeedsPassword() throws {
        let url = try corpus.encryptedPDF(password: "pw")
        XCTAssertThrowsError(try WorkingDocument(opening: url, sessionStore: nil)) {
            XCTAssertTrue(($0 as? SourceLoadError)?.needsPassword == true)
        }
        XCTAssertEqual(try WorkingDocument(opening: url, password: "pw", sessionStore: nil).preview.document.pageCount,
                       2)
    }

    func testChangeUpdatesPreviewSessionAndNotifies() throws {
        let document = try WorkingDocument(opening: corpus.pdf(named: "A", pages: 3), sessionStore: store)
        var notifications = 0
        document.onChange = { notifications += 1 }

        try document.change { try $0.rotate([$0.pages[1].id], by: .quarter) }
        XCTAssertEqual(document.preview.document.page(at: 1)?.rotation, 90)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(try store.load(document.plan.id), document.plan)

        try document.change { _ in }                        // keine Änderung
        XCTAssertEqual(notifications, 1)

        try document.undo()
        XCTAssertEqual(document.preview.document.page(at: 1)?.rotation, 0)
        try document.redo()
        XCTAssertEqual(notifications, 3)

        document.discardSession()
        XCTAssertEqual(try store.loadAll().sessions.count, 0)
    }

    func testFailedChangeLeavesEverythingUnchanged() throws {
        let document = try WorkingDocument(opening: corpus.pdf(named: "A", pages: 2), sessionStore: store)
        let plan = document.plan
        let preview = document.preview.document
        XCTAssertThrowsError(try document.change { try $0.remove([UUID()]) })
        XCTAssertEqual(document.plan, plan)
        XCTAssertTrue(document.preview.document === preview)
    }

    func testRestoredSessionBecomesDocument() throws {
        let document = try WorkingDocument(opening: corpus.pdf(named: "A", pages: 3), sessionStore: store)
        try document.change { try $0.move([$0.pages[2].id], to: 0) }
        let restored = RestoredSession(try store.load(document.plan.id))
        let reopened = try WorkingDocument(restored: restored, sessionStore: store)
        XCTAssertEqual(reopened.preview.document.page(at: 0)?.string?.contains("A page 3"), true)
    }
}

final class WorkshopTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        Localization.current = .de
        super.tearDown()
    }

    /// Mehrere abgelegte Dateien sind ein einziger Undo-Schritt.
    func testInsertFilesIsOneUndoStep() throws {
        let document = try WorkingDocument(opening: corpus.pdf(named: "A", pages: 2), sessionStore: nil)
        let files = [
            try SourceLoader.load(corpus.pdf(named: "B", pages: 2)),
            try SourceLoader.load(corpus.image(named: "Photo", format: .jpeg)),
        ]
        try document.insertFiles(files, at: 1)
        let texts = (0..<5).map { document.preview.document.page(at: $0)?.string ?? "" }
        XCTAssertTrue(texts[0].contains("A page 1"))
        XCTAssertTrue(texts[1].contains("B page 1"))
        XCTAssertTrue(texts[2].contains("B page 2"))
        XCTAssertTrue(texts[3].isEmpty)                                 // das Bild
        XCTAssertTrue(texts[4].contains("A page 2"))
        XCTAssertEqual(document.plan.sources.count, 3)
        XCTAssertEqual(document.plan.undoStack.count, 1)

        try document.undo()
        XCTAssertEqual(document.preview.document.pageCount, 2)
        XCTAssertEqual(document.plan.sources.count, 1)
        try document.insertFiles([], at: 0)
        XCTAssertFalse(document.plan.canUndo)
    }

    func testDefaultFolderAndStem() throws {
        let url = try corpus.pdf(named: "Vertrag (bearbeitet) 2", pages: 1)
        let document = try WorkingDocument(opening: url, sessionStore: nil)
        XCTAssertEqual(document.defaultFolder?.resolvingSymlinksInPath(),
                       corpus.directory.resolvingSymlinksInPath())
        XCTAssertEqual(document.stem, "Vertrag")
    }

    func testExtractBaseName() {
        Localization.current = .de
        XCTAssertEqual(Splitter.extractBaseName(stem: "Vertrag", positions: [4, 2, 3]), "Vertrag (3–5)")
        XCTAssertEqual(Splitter.extractBaseName(stem: "Vertrag", positions: [6]), "Vertrag (7)")
        XCTAssertEqual(Splitter.extractBaseName(stem: "Vertrag", positions: [0, 2]), "Vertrag (Auszug)")
        Localization.current = .en
        XCTAssertEqual(Splitter.extractBaseName(stem: "Contract", positions: [0, 5]), "Contract (extract)")
    }
}
