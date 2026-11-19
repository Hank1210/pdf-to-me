import DocKit
import PDFKit
import XCTest
@testable import PDFToMeCore

final class TextRecognitionRunTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    private func open(_ url: URL) throws -> WorkingDocument {
        try WorkingDocument(opening: url, sessionStore: nil)
    }

    /// Erkennt alle Seiten eines Dokuments und gibt die Ergebnisse in der Reihenfolge der Seiten zurück.
    private func recognizeAll(_ document: WorkingDocument) async throws -> [RecognizedPage] {
        try document.markForTextRecognition(document.plan.pages.map(\.id))
        try await TextRecognitionRun.run(document.pendingRecognition, cache: document.recognitionCache)
        return try document.plan.pages.map { page in
            try XCTUnwrap(document.recognitionCache[.init(source: document.plan.source(of: page)!, page: page)])
        }
    }

    // MARK: Auswahl

    /// Nur Seiten ohne Textebene werden vorgemerkt; Seiten mit Text bleiben, wie sie sind.
    func testOnlyPagesWithoutTextAreMarked() throws {
        let document = try open(corpus.pdf(named: "Contract", pages: 2))
        let scan = try SourceLoader.load(corpus.scannedTextPDF(named: "Scan", pages: [["Rechnung"]]))
        try document.insertFiles([scan], at: 1)
        let ids = document.plan.pages.map(\.id)

        XCTAssertEqual(try document.markForTextRecognition(ids), 1)
        XCTAssertEqual(document.plan.pages.map(\.recognizesText), [false, true, false])
        // Nochmals: nichts Neues, kein weiterer Undo-Schritt.
        let steps = document.plan.undoStack.count
        XCTAssertEqual(try document.markForTextRecognition(ids), 0)
        XCTAssertEqual(document.plan.undoStack.count, steps)
        try document.undo()
        XCTAssertFalse(document.plan.pages.contains { $0.recognizesText })
    }

    /// Abbrechen nimmt die Vormerkung der Seiten dieses Durchlaufs zurück; fertige Ergebnisse bleiben.
    func testStopTextRecognitionKeepsResults() throws {
        let document = try open(corpus.scannedTextPDF(named: "Scan", pages: [["Eins"], ["Zwei"], ["Drei"]]))
        let run = try document.markedForTextRecognition(document.plan.pages.map(\.id))
        XCTAssertEqual(run.count, 3)
        document.recognitionCache[document.pendingRecognition[0].key] = RecognizedPage(lines: [])
        try document.change { try $0.remove([run[2]]) }   // während der Erkennung gelöscht
        try document.stopTextRecognition(run)
        XCTAssertFalse(document.plan.pages.contains { $0.recognizesText })
        XCTAssertEqual(document.recognitionCache.count, 1)
        // Neu gestartet: Die erste Seite ist sofort fertig.
        try document.markForTextRecognition(document.plan.pages.map(\.id))
        XCTAssertEqual(document.pendingRecognition.map(\.key.pageIndex), [1])
    }

    func testImagePagesHaveNoText() throws {
        let document = try open(corpus.textImageFile(named: "Beleg", lines: ["Beleg"], size: CGSize(width: 600, height: 800)))
        XCTAssertEqual(try document.markForTextRecognition(document.plan.pages.map(\.id)), 1)
    }

    /// Dieselbe Quellseite mehrfach im Dokument wird nur einmal erkannt.
    func testPendingJobsAreUniquePerSourcePage() throws {
        let document = try open(corpus.scannedTextPDF(named: "Scan", pages: [["Eins"], ["Zwei"]]))
        let source = document.plan.sources[0]
        try document.change { try $0.insert([PageRef(source: source.id, index: 0)], at: 2) }
        try document.markForTextRecognition(document.plan.pages.map(\.id))
        XCTAssertEqual(document.pendingRecognition.map(\.key.pageIndex), [0, 1])
        XCTAssertEqual(document.pendingRecognition.map(\.pageNumber), [1, 2])
        document.recognitionCache[document.pendingRecognition[0].key] = RecognizedPage(lines: [])
        XCTAssertEqual(document.pendingRecognition.map(\.key.pageIndex), [1])
    }

    // MARK: Erkennen

    func testRecognizesScannedPage() async throws {
        try requireTextRecognition()
        let document = try open(corpus.scannedTextPDF(
            named: "Scan", pages: [["Stromrechnung Mai", "Kundennummer 4711", "Betrag 52 Euro"]]))
        let page = try await recognizeAll(document)[0]
        XCTAssertTrue(page.text.contains("Stromrechnung"), page.text)
        XCTAssertTrue(page.text.contains("4711"), page.text)
        // Erste Zeile oben auf der Seite (Ursprung unten links), alle Kästen innerhalb der Seite.
        let first = try XCTUnwrap(page.lines.first)
        XCTAssertTrue(first.text.contains("Stromrechnung"))
        XCTAssertGreaterThan(first.box.midY, 0.85)
        XCTAssertLessThan(first.box.minX, 0.15)
        XCTAssertTrue(page.lines.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.box) })
    }

    /// Eine quer eingelegte Seite mit `/Rotate 90` wird so erkannt, wie sie angezeigt wird.
    func testRecognizesRotatedPageAsDisplayed() async throws {
        try requireTextRecognition()
        let document = try open(corpus.scannedTextPDF(named: "Quer", pages: [["Kontoauszug Juni"]], rotated: true))
        XCTAssertEqual(document.contents.values.first.flatMap { content -> Int? in
            if case let .pdf(pdf, _) = content { return pdf.page(at: 0)?.rotation } else { return nil }
        }, 90)
        let page = try await recognizeAll(document)[0]
        XCTAssertTrue(page.text.contains("Kontoauszug"), page.text)
        XCTAssertGreaterThan(try XCTUnwrap(page.lines.first).box.midY, 0.85)
    }

    /// Nur der sichtbare Ausschnitt zählt; Kästen beziehen sich auf ihn.
    func testRecognizesOnlyTheCropBox() async throws {
        try requireTextRecognition()
        var lines = Array(repeating: "", count: 16)
        lines[0] = "Oben sichtbar"
        lines[15] = "Unten abgeschnitten"
        let document = try open(corpus.scannedTextPDF(named: "Ausschnitt", pages: [lines], cropToTopHalf: true))
        let page = try await recognizeAll(document)[0]
        XCTAssertTrue(page.text.contains("Oben"), page.text)
        XCTAssertFalse(page.text.contains("Unten"), page.text)
        // In der oberen Hälfte der Seite liegt die Zeile bei der Hälfte als Ausschnitt ganz oben.
        XCTAssertGreaterThan(try XCTUnwrap(page.lines.first).box.midY, 0.75)
    }

    /// Bei Bildern liegen die Kästen dort, wo das Bild auf der A4-Seite steht.
    func testImageBoxesFollowThePagePlacement() async throws {
        try requireTextRecognition()
        // Querformat 2:1 auf A4 quer: Das Bild füllt die Breite, oben und unten bleibt Rand.
        let size = CGSize(width: 1600, height: 800)
        let document = try open(corpus.textImageFile(named: "Foto", lines: ["Quittung Baumarkt"], size: size))
        let page = try await recognizeAll(document)[0]
        let line = try XCTUnwrap(page.lines.first { $0.text.contains("Quittung") })
        let fitted = ImagePage.fittedRect(
            imageSize: size, in: CGRect(origin: .zero, size: ImagePage.a4Landscape))
        let band = (fitted.minY / ImagePage.a4Landscape.height)...(fitted.maxY / ImagePage.a4Landscape.height)
        XCTAssertTrue(band.contains(line.box.midY), "\(line.box) außerhalb von \(band)")
        // Die erste Zeile steht im Bild oben, also nahe der Oberkante des Bildbereichs.
        XCTAssertGreaterThan(line.box.midY, band.upperBound - 0.15)
    }

    // MARK: Abbrechen und Fehler

    func testCancelKeepsFinishedPages() async throws {
        try requireTextRecognition()
        let document = try open(corpus.scannedTextPDF(named: "Drei", pages: [["Eins"], ["Zwei"], ["Drei"]]))
        try document.markForTextRecognition(document.plan.pages.map(\.id))
        let jobs = document.pendingRecognition
        let cache = document.recognitionCache
        let task = Task {
            try await TextRecognitionRun.run(jobs, cache: cache) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            try await task.value
            XCTFail("hätte abbrechen müssen")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(document.pendingRecognition.count, 2)
    }

    /// Eine Zeitüberschreitung wird mit Seitennummer und Ursache gemeldet.
    func testTimeoutNamesThePage() async throws {
        let document = try open(corpus.scannedTextPDF(named: "Langsam", pages: [["Eins"], ["Zwei"]]))
        try document.markForTextRecognition([document.plan.pages[1].id])
        do {
            try await TextRecognitionRun.run(document.pendingRecognition, cache: document.recognitionCache,
                                             timeout: 0.000_1)
            XCTFail("hätte die Zeit überschreiten müssen")
        } catch {
            XCTAssertEqual(error as? TextRecognitionError, .pageFailed(
                page: 2, reason: TextRecognizerError.timedOut.errorDescription))
        }
        Localization.current = .en
        defer { Localization.current = .de }
        XCTAssertTrue(TextRecognitionError.pageFailed(page: 2, reason: nil).errorDescription!.contains("page 2"))
    }

    func testUnreadableSourceIsReported() async throws {
        let source = SourceFile(kind: .pdf, displayName: "Kaputt.pdf", bookmark: Data([1]),
                                sha256: String(repeating: "c", count: 64), pageCount: 1)
        var plan = try DocumentPlan(source: source)
        try plan.recognizeText(plan.pages.map(\.id))
        let contents: SourceContents = [source.id: .pdf(PDFDocument(), data: Data("kein PDF".utf8))]
        let jobs = TextRecognitionRun.pendingJobs(plan: plan, contents: contents, cache: TextRecognitionCache())
        do {
            try await TextRecognitionRun.run(jobs, cache: TextRecognitionCache())
            XCTFail("hätte scheitern müssen")
        } catch {
            XCTAssertEqual(error as? TextRecognitionError, .pageFailed(page: 1, reason: nil))
        }
    }
}
