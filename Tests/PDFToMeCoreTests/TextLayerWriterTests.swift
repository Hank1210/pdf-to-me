import AppKit
import DocKit
import PDFKit
import XCTest
@testable import PDFToMeCore

/// Schreiben der Textebene: Erkannte Seiten werden durchsuchbar, ohne dass sich ihr Aussehen ändert.
///
/// Die Ergebnisse der Erkennung werden hier fest vorgegeben, damit bekannt ist, wo jede Zeile liegen muss, und die
/// Tests ohne Vision laufen. Ein Test geht einmal mit echter Erkennung durch die ganze Kette.
final class TextLayerWriterTests: XCTestCase {
    private var corpus: TestCorpus!
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

    private let line = RecognizedLine(text: "Synthetische Zeile 4711", box: CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.03))

    /// Merkt alle Seiten ohne Text vor und hinterlegt für jede das Ergebnis `page`.
    private func markAll(_ document: WorkingDocument, with page: RecognizedPage) throws {
        try document.markForTextRecognition(document.plan.pages.map(\.id))
        for job in document.pendingRecognition { document.recognitionCache[job.key] = page }
    }

    private func save(_ document: WorkingDocument, password: String? = nil) throws -> URL {
        try SavePipeline(writer: QPDFKitWriter()).save(
            document.plan, contents: document.contents, in: output, baseName: "Result",
            options: WriteOptions(password: password, textLayers: document.recognitionCache)).url
    }

    private func bounds(of text: String, in url: URL, page index: Int = 0, password: String? = nil) throws -> CGRect {
        let document = try XCTUnwrap(PDFDocument(url: url))
        if let password { XCTAssertTrue(document.unlock(withPassword: password)) }
        let page = try XCTUnwrap(document.page(at: index))
        let selection = try XCTUnwrap(document.findString(text, withOptions: []).first { $0.pages.contains(page) },
                                      "\(text) nicht gefunden")
        return selection.bounds(for: page)
    }

    private func assertNear(_ value: CGFloat, _ expected: ClosedRange<CGFloat>, _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(expected.contains(value), "\(label) \(value) nicht in \(expected)", file: file, line: line)
    }

    // MARK: Lage der Textebene

    func testTextLayerOnUprightPage() throws {
        let document = try WorkingDocument(opening: corpus.scannedTextPDF(named: "Scan", pages: [["Bild"]]), sessionStore: nil)
        try markAll(document, with: RecognizedPage(lines: [line]))
        let url = try save(document)
        let box = try bounds(of: "4711", in: url)
        // Zeile bei x 0,1…0,6 und y 0,9…0,93 von A4 (595 × 842).
        assertNear(box.midX, 59...357, "x")
        assertNear(box.midY, 758...783, "y")
        XCTAssertEqual(try QPDFCheck.run(url, password: nil).get().warnings, 0)
    }

    /// Quer eingelegte Seite mit `/Rotate 90`: Die Textebene steht so, wie die Seite angezeigt wird.
    func testTextLayerOnRotatedPage() throws {
        let document = try WorkingDocument(
            opening: corpus.scannedTextPDF(named: "Quer", pages: [["Bild"]], rotated: true), sessionStore: nil)
        try markAll(document, with: RecognizedPage(lines: [line]))
        let url = try save(document)
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.rotation, 90)
        // Angezeigt 595 × 842; im Seitenraum (842 × 595, im Uhrzeigersinn angezeigt) liegt die Zeile senkrecht
        // am linken Rand: x = 842 − y_angezeigt, y = x_angezeigt.
        let box = try bounds(of: "4711", in: url)
        assertNear(box.midX, 59...84, "x")
        assertNear(box.midY, 59...357, "y")
    }

    /// Mit Ausschnitt: Die Textebene liegt im sichtbaren Teil.
    func testTextLayerInsideCropBox() throws {
        let document = try WorkingDocument(
            opening: corpus.scannedTextPDF(named: "Oben", pages: [["Bild"]], cropToTopHalf: true), sessionStore: nil)
        let low = RecognizedLine(text: "Weiter unten 0815", box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05))
        try markAll(document, with: RecognizedPage(lines: [line, low]))
        let url = try save(document)
        // Ausschnitt ist y 421…842; 0,1 davon liegt bei 421 + 42.
        assertNear(try bounds(of: "0815", in: url).midY, 455...490, "y unten")
        assertNear(try bounds(of: "4711", in: url).midY, 795...830, "y oben")
    }

    /// Die zusätzliche Drehung aus dem Plan dreht Seite und Textebene gemeinsam.
    func testPlanRotationTurnsTextLayerWithPage() throws {
        let document = try WorkingDocument(opening: corpus.scannedTextPDF(named: "Scan", pages: [["Bild"]]), sessionStore: nil)
        try markAll(document, with: RecognizedPage(lines: [line]))
        try document.change { try $0.rotate([$0.pages[0].id], by: .quarter) }
        let url = try save(document)
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.rotation, 90)
        // Im Seitenraum unverändert wie ohne Drehung.
        assertNear(try bounds(of: "4711", in: url).midY, 758...783, "y")
    }

    func testTextLayerOnImagePage() throws {
        let document = try WorkingDocument(
            opening: corpus.textImageFile(named: "Foto", lines: ["Bild"], size: CGSize(width: 1600, height: 800)),
            sessionStore: nil)
        let onPage = RecognizedLine(text: "Quittung 1234", box: CGRect(x: 0.1, y: 0.6, width: 0.4, height: 0.05))
        try markAll(document, with: RecognizedPage(lines: [onPage]))
        let url = try save(document)
        // A4 quer, 842 × 595.
        let box = try bounds(of: "1234", in: url)
        assertNear(box.midX, 84...421, "x")
        assertNear(box.midY, 357...387, "y")
    }

    // MARK: Seite bleibt unverändert

    /// Die Seite sieht mit Textebene pixelgenau aus wie ohne.
    func testPageLooksTheSame() throws {
        let scan = try corpus.scannedTextPDF(named: "Scan", pages: [["Stromrechnung", "Kundennummer 4711"]])
        let document = try WorkingDocument(opening: scan, sessionStore: nil)
        try markAll(document, with: RecognizedPage(lines: [line]))
        let url = try save(document)
        XCTAssertEqual(try pixels(of: url), try pixels(of: scan))
    }

    private func pixels(of url: URL) throws -> [UInt8] {
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let image = try XCTUnwrap(TextRecognitionRun.render(page))
        let bitmap = NSBitmapImageRep(cgImage: image)
        return Array(UnsafeBufferPointer(start: bitmap.bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    // MARK: Doppelte Seiten

    /// Dieselbe Quellseite zweimal: Nur die vorgemerkte bekommt die Textebene.
    func testDuplicateWithoutRecognitionStaysWithoutText() throws {
        let document = try WorkingDocument(opening: corpus.scannedTextPDF(named: "Scan", pages: [["Bild"]]), sessionStore: nil)
        let source = document.plan.sources[0]
        try document.change { try $0.insert([PageRef(source: source.id, index: 0)], at: 1) }
        try document.markForTextRecognition([document.plan.pages[1].id])
        for job in document.pendingRecognition { document.recognitionCache[job.key] = RecognizedPage(lines: [line]) }
        let url = try save(document)
        let written = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue((written.page(at: 0)?.string ?? "").isEmpty)
        XCTAssertTrue(written.page(at: 1)?.string?.contains("4711") ?? false)
    }

    /// Wird die erste von zwei gleichen Seiten gedreht, bleibt die zweite ungedreht (früher drehte sie mit).
    func testDuplicateDoesNotInheritRotationOfFirstCopy() throws {
        let document = try WorkingDocument(opening: corpus.pdf(named: "Contract", pages: 1), sessionStore: nil)
        let source = document.plan.sources[0]
        try document.change { try $0.insert([PageRef(source: source.id, index: 0)], at: 1) }
        try document.change { try $0.rotate([$0.pages[0].id], by: .quarter) }
        let url = try save(document)
        let written = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(written.page(at: 0)?.rotation, 90)
        XCTAssertEqual(written.page(at: 1)?.rotation, 0)
    }

    // MARK: Zusammenspiel

    func testProtectedOutputKeepsTextLayer() throws {
        let document = try WorkingDocument(opening: corpus.scannedTextPDF(named: "Scan", pages: [["Bild"]]), sessionStore: nil)
        try markAll(document, with: RecognizedPage(lines: [line]))
        let url = try save(document, password: "test-password")
        XCTAssertTrue(PDFDocument(url: url)?.isLocked ?? false)
        assertNear(try bounds(of: "4711", in: url, password: "test-password").midY, 758...783, "y")
    }

    func testSplitPartsKeepTextLayer() throws {
        let document = try WorkingDocument(
            opening: corpus.scannedTextPDF(named: "Scan", pages: [["Eins"], ["Zwei"]]), sessionStore: nil)
        try markAll(document, with: RecognizedPage(lines: [line]))
        let results = Splitter.save(
            document.plan, contents: document.contents, parts: [SplitPart(first: 2, last: 2)], in: output,
            stem: "Scan", pipeline: SavePipeline(writer: QPDFKitWriter()),
            options: WriteOptions(textLayers: document.recognitionCache))
        let url = try results[0].result.get().url
        XCTAssertTrue(PDFDocument(url: url)?.page(at: 0)?.string?.contains("4711") ?? false)
    }

    // MARK: Fehler

    /// Ohne Ergebnis wird nicht geschrieben; die Meldung nennt die Seite.
    func testMissingResultStopsWriting() throws {
        let document = try WorkingDocument(
            opening: corpus.scannedTextPDF(named: "Scan", pages: [["Eins"], ["Zwei"]]), sessionStore: nil)
        try document.markForTextRecognition([document.plan.pages[1].id])
        XCTAssertThrowsError(try save(document)) {
            XCTAssertEqual($0 as? WriterError, .textNotRecognized(page: 2))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    /// Die Prüfung erkennt, wenn der erkannte Text in der neuen Datei fehlt.
    func testVerifierReportsMissingRecognizedText() throws {
        let document = try WorkingDocument(opening: corpus.scannedTextPDF(named: "Scan", pages: [["Bild"]]), sessionStore: nil)
        try markAll(document, with: RecognizedPage(lines: [line]))
        let url = try save(document)
        let other = TextRecognitionCache()
        other[document.pendingRecognition.first?.key ?? .init(source: document.plan.sources[0], page: document.plan.pages[0])] =
            RecognizedPage(lines: [RecognizedLine(text: "Ganz anderer Text", box: line.box)])
        let failures = SaveVerifier.failures(
            of: url, expected: document.preview, plan: document.plan, contents: document.contents, password: nil,
            textLayers: other)
        XCTAssertEqual(failures, [.recognizedTextMissing(page: 1)])
    }

    // MARK: Ganze Kette

    /// Mit echter Erkennung: Scan öffnen, Text erkennen, speichern, in der neuen Datei suchen.
    func testRecognizeAndSaveEndToEnd() async throws {
        try requireTextRecognition()
        let document = try WorkingDocument(
            opening: corpus.scannedTextPDF(named: "Scan", pages: [["Stromrechnung Mai", "Kundennummer 4711"]]),
            sessionStore: nil)
        try document.markForTextRecognition(document.plan.pages.map(\.id))
        try await TextRecognitionRun.run(document.pendingRecognition, cache: document.recognitionCache)
        let url = try save(document)
        let written = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(written.findString("Stromrechnung", withOptions: .caseInsensitive).count, 1)
        // Die Überschrift steht oben auf der Seite.
        XCTAssertGreaterThan(try bounds(of: "Stromrechnung", in: url).midY, 700)
    }
}
