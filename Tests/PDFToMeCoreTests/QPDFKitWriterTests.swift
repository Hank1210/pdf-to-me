import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import PDFToMeCore

/// Fälle, die über die gemeinsamen Rundlauf-Tests hinausgehen und die der qpdf-Writer besonders behandelt.
final class QPDFKitWriterTests: XCTestCase {
    private var corpus: TestCorpus!
    private var plan: DocumentPlan!
    private var contents: SourceContents = [:]

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    @discardableResult
    private func add(_ url: URL, password: String? = nil) throws -> SourceFile {
        let loaded = try SourceLoader.load(url, password: password)
        contents[loaded.source.id] = loaded.content
        if plan == nil {
            plan = try DocumentPlan(source: loaded.source)
        } else {
            try plan.insertPages(of: loaded.source, at: plan.pages.count)
        }
        return loaded.source
    }

    private func write(password: String? = nil) throws -> (PDFDocument, URL) {
        let url = corpus.url("Out-\(UUID().uuidString).pdf")
        try QPDFKitWriter().compose(plan, contents: contents, to: url, options: WriteOptions(password: password))
        let document = try XCTUnwrap(PDFDocument(url: url))
        if let password { XCTAssertTrue(document.unlock(withPassword: password)) }
        return (document, url)
    }

    private func links(_ document: PDFDocument, page: Int) -> [PDFAnnotation] {
        document.page(at: page)?.annotations.filter { $0.type == "Link" } ?? []
    }

    private func target(_ link: PDFAnnotation, in document: PDFDocument) -> Int? {
        ((link.action as? PDFActionGoTo)?.destination.page ?? link.destination?.page).map(document.index(for:))
    }

    // MARK: Benannte Ziele

    /// Eine PDF mit einem Link, dessen Ziel über das Namensverzeichnis `/Names /Dests` definiert ist.
    private func namedDestinationPDF() throws -> URL {
        func page(_ number: Int, annots: String = "") -> String {
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] \(annots) /Contents \(number + 5) 0 R "
                + "/Resources << /Font << /F1 9 0 R >> >> >>"
        }
        func content(_ number: Int) -> String {
            let text = "BT /F1 18 Tf 72 742 Td (Named page \(number)) Tj ET"
            return "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Names << /Dests << /Names [(chapter3) [5 0 R /Fit]] >> >> "
                + "/Outlines 10 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            page(1, annots: "/Annots [11 0 R]"), page(2), page(3),
            content(1), content(2), content(3),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Outlines /First 12 0 R /Last 12 0 R /Count 1 >>",
            "<< /Type /Annot /Subtype /Link /Rect [72 400 272 420] /Border [0 0 0] /Dest (chapter3) >>",
            "<< /Title (Chapter 3) /Parent 10 0 R /Dest (chapter3) >>",
        ]
        let url = corpus.url("Named.pdf")
        try Data(TestCorpus.pdfFile(objects: objects).utf8).write(to: url)
        return url
    }

    func testNamedDestinationsAreResolved() throws {
        let url = try namedDestinationPDF()
        // Vorbedingung: PDFKit löst das benannte Ziel in der Quelle auf.
        let source = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(links(source, page: 0).first.flatMap { target($0, in: source) }, 2)

        try add(url)
        try plan.move([plan.pages[2].id], to: 0)            // Reihenfolge 3, 1, 2
        let (document, _) = try write()
        XCTAssertEqual(links(document, page: 1).first.flatMap { target($0, in: document) }, 0)
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.label, "Chapter 3")
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.destination?.page.map(document.index(for:)), 0)
    }

    func testNamedDestinationToRemovedPageIsDropped() throws {
        try add(namedDestinationPDF())
        try plan.remove([plan.pages[2].id])
        let (document, _) = try write()
        XCTAssertTrue(links(document, page: 0).isEmpty)
        XCTAssertNil(document.outlineRoot)
    }

    // MARK: Doppelte Seiten und Formulare

    func testDuplicatePageGetsOwnLinks() throws {
        let linked = try add(corpus.linkedPDF())
        try plan.insert([PageRef(source: linked.id, index: 0)], at: 3)
        let (document, _) = try write()
        XCTAssertEqual(document.pageCount, 4)
        XCTAssertEqual(links(document, page: 0).first.flatMap { target($0, in: document) }, 2)
        XCTAssertEqual(links(document, page: 3).first.flatMap { target($0, in: document) }, 2)
        XCTAssertFalse(links(document, page: 0).first === links(document, page: 3).first)
    }

    /// Zweimal dasselbe Formular: Beide bleiben ausfüllbar; qpdf benennt gleichnamige Felder um.
    func testSameFormTwiceStaysFillable() throws {
        try add(corpus.formPDF(named: "First"))
        try add(corpus.formPDF(named: "Second"))
        let (_, url) = try write()
        let names = FormFields.names(at: url, password: nil)
        XCTAssertTrue(names.isSuperset(of: ["name", "agree"]), "\(names)")
        XCTAssertGreaterThanOrEqual(names.count, 4, "\(names)")
    }

    func testFormInProtectedOutputStaysFillable() throws {
        try add(corpus.formPDF())
        let (_, url) = try write(password: "pw")
        XCTAssertEqual(FormFields.names(at: url, password: "pw"), ["name", "agree"])
    }

    // MARK: Inhaltsverzeichnis

    /// Ein zugeklappter Eintrag bleibt zugeklappt, ein aufgeklappter aufgeklappt (Vorzeichen von `/Count`).
    func testOutlineKeepsOpenState() throws {
        // Von Hand geschrieben: Part 1 aufgeklappt (/Count 1), Part 2 zugeklappt (/Count -1), je mit Unterpunkt.
        func page(_ number: Int) -> String {
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents \(number + 5) 0 R >>"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 9 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            page(1), page(2), page(3),
            "<< /Length 0 >>\nstream\n\nendstream", "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Outlines /First 10 0 R /Last 11 0 R /Count 3 >>",
            "<< /Title (Part 1) /Parent 9 0 R /Next 11 0 R /First 12 0 R /Last 12 0 R /Count 1 /Dest [3 0 R /Fit] >>",
            "<< /Title (Part 2) /Parent 9 0 R /Prev 10 0 R /First 13 0 R /Last 13 0 R /Count -1 "
                + "/Dest [4 0 R /Fit] >>",
            "<< /Title (Section 1) /Parent 10 0 R /Dest [4 0 R /Fit] >>",
            "<< /Title (Section 2) /Parent 11 0 R /Dest [5 0 R /Fit] >>",
        ]
        let url = corpus.url("TreeOutline.pdf")
        try Data(TestCorpus.pdfFile(objects: objects).utf8).write(to: url)
        let source = try XCTUnwrap(PDFDocument(url: url)?.outlineRoot)
        XCTAssertEqual([source.child(at: 0)?.isOpen, source.child(at: 1)?.isOpen], [true, false], "Vorbedingung")

        try add(url)
        let (document, _) = try write()
        let written = try XCTUnwrap(document.outlineRoot)
        XCTAssertEqual(written.numberOfChildren, 2)
        XCTAssertEqual(written.child(at: 0)?.isOpen, true)
        XCTAssertEqual(written.child(at: 1)?.isOpen, false)
        XCTAssertEqual(written.child(at: 1)?.child(at: 0)?.label, "Section 2")
    }

    // MARK: Bilder

    /// Das Bild steht aufrecht, unverzerrt und mittig auf einer A4-Seite, wie in der Vorschau.
    func testImagePageMatchesPreviewGeometry() throws {
        let url = corpus.url("Rotated.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try TestCorpus.makeImage(size: CGSize(width: 300, height: 200)),
            [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try add(url)

        let (document, _) = try write()
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).size, ImagePage.a4Portrait)
        let pixels = try Pixels(page)
        // Aufgerichtet 200 × 300 in 595 × 842: Faktor 2,807, Breite 561, Rand links und rechts je 17 Punkte.
        XCTAssertTrue(pixels.isWhite(at: CGPoint(x: 5, y: 421)), "left margin")
        XCTAssertTrue(pixels.isWhite(at: CGPoint(x: 590, y: 421)), "right margin")
        XCTAssertTrue(pixels.isYellow(at: CGPoint(x: 560, y: 60)), "marker top right")
        XCTAssertTrue(pixels.isBlue(at: CGPoint(x: 40, y: 60)), "no marker top left")
    }

    func testFittedRect() {
        let bounds = CGRect(origin: .zero, size: ImagePage.a4Landscape)
        let rect = ImagePage.fittedRect(imageSize: CGSize(width: 300, height: 200), in: bounds)
        XCTAssertEqual(rect.width, 842, accuracy: 0.01)
        XCTAssertEqual(rect.height, 561.33, accuracy: 0.01)
        XCTAssertEqual(rect.midY, bounds.midY, accuracy: 0.01)
    }

    // MARK: Fehler

    func testWrongSourcePasswordIsReported() throws {
        let source = try add(corpus.encryptedPDF(password: "pw"), password: "pw")
        try plan.setPassword("wrong", for: source.id)
        XCTAssertThrowsError(try write()) {
            XCTAssertEqual($0 as? SourceLoadError, .passwordRequired(fileName: "Encrypted.pdf"))
        }
    }

    func testMissingContentIsReported() throws {
        let source = try add(corpus.pdf(named: "A", pages: 1))
        contents[source.id] = nil
        XCTAssertThrowsError(try write()) {
            XCTAssertEqual($0 as? AssemblyError, .missingContent(fileName: "A.pdf"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: corpus.directory.path)
            .filter { $0.hasPrefix("Out-") }.isEmpty)
    }

    /// Mehrere Schreibvorgänge gleichzeitig: Die Sperre hält sie auseinander, alle Ergebnisse sind vollständig.
    func testConcurrentWrites() throws {
        try add(corpus.linkedPDF())
        try add(corpus.formPDF())
        let plan = self.plan!, contents = self.contents
        let urls = (0..<8).map { corpus.url("Parallel-\($0).pdf") }
        let failures = NSLock()
        nonisolated(unsafe) var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            do {
                try QPDFKitWriter().compose(plan, contents: contents, to: urls[index], options: WriteOptions())
            } catch {
                failures.withLock { errors.append(error) }
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        for url in urls {
            XCTAssertEqual(PDFDocument(url: url)?.pageCount, 4)
            XCTAssertEqual(FormFields.names(at: url, password: nil), ["name", "agree"])
        }
    }
}
