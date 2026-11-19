import ImageIO
import PDFKit
import XCTest
@testable import PDFToMeCore

/// Sichert ab, dass jede erzeugte Testdatei die Eigenschaft hat, die andere Tests von ihr erwarten.
final class CorpusTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    private func open(_ url: URL) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(url: url), url.lastPathComponent)
    }

    func testTextPDFHasMarkerOnEveryPage() throws {
        let document = try open(corpus.pdf(named: "Contract", pages: 4))
        XCTAssertEqual(document.pageCount, 4)
        for index in 0..<4 {
            let text = try XCTUnwrap(document.page(at: index)?.string)
            XCTAssertTrue(text.contains(TestCorpus.marker("Contract", page: index + 1)), text)
        }
        XCTAssertFalse(document.isEncrypted)
    }

    func testPageSizesAlternate() throws {
        let document = try open(corpus.pdf(
            named: "Sizes", pages: 3, sizes: [TestCorpus.a4, TestCorpus.a4Landscape]))
        let sizes = (0..<3).map { document.page(at: $0)!.bounds(for: .mediaBox).size }
        XCTAssertEqual(sizes, [TestCorpus.a4, TestCorpus.a4Landscape, TestCorpus.a4])
    }

    func testLargePDF() throws {
        let document = try open(corpus.pdf(named: "Large", pages: 500))
        XCTAssertEqual(document.pageCount, 500)
        XCTAssertTrue(document.page(at: 499)?.string?.contains("Large page 500") == true)
    }

    func testEncryptedPDFNeedsPassword() throws {
        let url = try corpus.encryptedPDF(password: "test-password")
        let document = try open(url)
        XCTAssertTrue(document.isEncrypted)
        XCTAssertTrue(document.isLocked)
        XCTAssertFalse(document.unlock(withPassword: "wrong"))
        XCTAssertTrue(document.unlock(withPassword: "test-password"))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Encrypted page 1") == true)
    }

    func testLinkedPDFHasOutlineAndLinks() throws {
        let document = try open(corpus.linkedPDF())
        XCTAssertEqual(document.pageCount, 3)

        let outline = try XCTUnwrap(document.outlineRoot)
        XCTAssertEqual(outline.numberOfChildren, 3)
        for index in 0..<3 {
            let child = try XCTUnwrap(outline.child(at: index))
            XCTAssertEqual(child.label, "Chapter \(index + 1)")
            XCTAssertEqual(child.destination?.page.map(document.index(for:)), index)
        }

        let internalLink = try XCTUnwrap(document.page(at: 0)?.annotations.first { $0.type == "Link" })
        let target = try XCTUnwrap(
            internalLink.destination?.page ?? (internalLink.action as? PDFActionGoTo)?.destination.page)
        XCTAssertEqual(document.index(for: target), 2)

        let external = try XCTUnwrap(document.page(at: 1)?.annotations.first { $0.type == "Link" })
        let url = external.url ?? (external.action as? PDFActionURL)?.url
        XCTAssertEqual(url, TestCorpus.externalLink)
    }

    func testFormPDFHasFields() throws {
        let document = try open(corpus.formPDF())
        let widgets = try XCTUnwrap(document.page(at: 0)?.annotations.filter { $0.type == "Widget" })
        let byName = Dictionary(uniqueKeysWithValues: widgets.compactMap { w in w.fieldName.map { ($0, w) } })
        XCTAssertEqual(Set(byName.keys), ["name", "agree"])
        XCTAssertEqual(byName["name"]?.widgetStringValue, "Jane Doe")
        XCTAssertEqual(byName["agree"]?.buttonWidgetState, .onState)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Form page 1") == true)
    }

    /// Die Felder stehen im Formularverzeichnis, sind also wirklich ausfüllbar (nicht nur sichtbare Widgets).
    func testFormPDFHasAcroForm() throws {
        XCTAssertEqual(FormFields.names(at: try corpus.formPDF(), password: nil), ["name", "agree"])
        XCTAssertEqual(FormFields.names(at: try corpus.pdf(named: "Plain", pages: 1), password: nil), [])
    }

    func testScannedPDFHasNoText() throws {
        let document = try open(corpus.scannedPDF())
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue((document.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testMixedScriptPDFContainsAllLines() throws {
        let document = try open(corpus.mixedScriptPDF())
        let text = try XCTUnwrap(document.page(at: 0)?.string)
        // Ligaturen und Umlaute müssen als einzelne Zeichen herauskommen.
        XCTAssertTrue(text.contains("office affinity ffi"), text)
        XCTAssertTrue(text.contains("Grüße aus Köln"), text)
        // Bei Rechts-nach-links-Text reicht für den Korpus, dass die Zeichen vorhanden sind.
        for line in TestCorpus.mixedScriptLines.suffix(2) {
            let letters = Set(line.filter { !$0.isWhitespace })
            XCTAssertTrue(letters.isSubset(of: Set(text)), "\(line) / \(text)")
        }
    }

    func testDamagedFilesDoNotOpen() throws {
        for url in [try corpus.truncatedPDF(), try corpus.notAPDF(), try corpus.emptyFile()] {
            XCTAssertNil(PDFDocument(url: url), url.lastPathComponent)
        }
    }

    func testImagesHaveRequestedFormatAndSize() throws {
        for format in TestCorpus.ImageFormat.allCases {
            let url = try corpus.image(named: "Photo", format: format, size: CGSize(width: 300, height: 200))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "\(format)")
            XCTAssertEqual(CGImageSourceGetType(source) as String?, format.type.identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 300)
            XCTAssertEqual(image.height, 200)
        }
    }

    func testCorpusIsRemoved() throws {
        let url = try corpus.pdf(named: "Temp", pages: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        corpus.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: corpus.directory.path))
    }

    /// Scan-Seiten tragen ihren Text nur als Bild; gedreht und mit Ausschnitt, wenn verlangt.
    func testScannedTextPDFHasNoTextLayer() throws {
        let plain = try XCTUnwrap(PDFDocument(url: corpus.scannedTextPDF(named: "S1", pages: [["Eins"], ["Zwei"]])))
        XCTAssertEqual(plain.pageCount, 2)
        XCTAssertTrue((plain.page(at: 0)?.string ?? "").isEmpty)

        let turned = try XCTUnwrap(PDFDocument(url: corpus.scannedTextPDF(named: "S2", pages: [["Quer"]], rotated: true)))
        XCTAssertEqual(turned.page(at: 0)?.rotation, 90)
        XCTAssertEqual(turned.page(at: 0)?.bounds(for: .mediaBox).size, TestCorpus.a4Landscape)
        XCTAssertTrue((turned.page(at: 0)?.string ?? "").isEmpty)

        let cropped = try XCTUnwrap(PDFDocument(url: corpus.scannedTextPDF(named: "S3", pages: [["Oben"]], cropToTopHalf: true)))
        XCTAssertEqual(cropped.page(at: 0)?.bounds(for: .cropBox).height ?? 0, TestCorpus.a4.height / 2, accuracy: 1)
    }
}
