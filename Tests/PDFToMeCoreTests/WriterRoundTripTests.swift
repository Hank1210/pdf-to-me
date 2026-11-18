import CryptoKit
import PDFKit
import XCTest
@testable import PDFToMeCore

/// Rundlauf-Tests: Plan bauen, schreiben, die Datei frisch öffnen und vergleichen.
///
/// Laufen gegen jeden Writer in `writers`. In M1b kommt `PDFiumWriter` dazu; beide müssen dieselben Tests bestehen.
final class WriterRoundTripTests: XCTestCase {
    private let writers: [(name: String, writer: any PDFWriting)] = [("PDFKit", PDFKitWriter())]

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

    /// Schreibt den Plan mit jedem Writer und gibt die frisch geöffneten Ergebnisse zurück.
    private func writeAndReopen(
        options: WriteOptions = WriteOptions(), file: StaticString = #filePath, line: UInt = #line
    ) throws -> [(name: String, document: PDFDocument)] {
        try writers.map { entry in
            let url = corpus.url("Out-\(entry.name)-\(UUID().uuidString).pdf")
            try entry.writer.compose(plan, contents: contents, to: url, options: options)
            let document = try XCTUnwrap(PDFDocument(url: url), entry.name, file: file, line: line)
            if let password = options.password { XCTAssertTrue(document.unlock(withPassword: password)) }
            return (entry.name, document)
        }
    }

    private func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func linkTarget(_ annotation: PDFAnnotation) -> PDFPage? {
        (annotation.action as? PDFActionGoTo)?.destination.page ?? annotation.destination?.page
    }

    // MARK: Seitenoperationen

    func testMergeReorderRotateRemove() throws {
        try add(corpus.pdf(named: "A", pages: 3, sizes: [TestCorpus.a4, TestCorpus.a4Landscape]))
        try add(corpus.pdf(named: "B", pages: 2))
        try plan.move([plan.pages[3].id], to: 0)           // B1 nach vorn
        try plan.remove([plan.pages[2].id])                 // A2 weg
        try plan.rotate([plan.pages[1].id], by: .threeQuarters)

        for (name, document) in try writeAndReopen() {
            XCTAssertEqual(texts(document), ["B page 1", "A page 1", "A page 3", "B page 2"], name)
            XCTAssertEqual((0..<4).map { document.page(at: $0)!.rotation }, [0, 270, 0, 0], name)
            XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, TestCorpus.a4, name)
        }
    }

    func testExtractedPlan() throws {
        try add(corpus.pdf(named: "A", pages: 5))
        plan = try plan.extracting([plan.pages[3].id, plan.pages[1].id])
        for (name, document) in try writeAndReopen() {
            XCTAssertEqual(texts(document), ["A page 2", "A page 4"], name)
        }
    }

    func testImagesAsPages() throws {
        try add(corpus.pdf(named: "A", pages: 1))
        try add(corpus.image(named: "Photo", format: .heic, size: CGSize(width: 300, height: 200)))
        try add(corpus.image(named: "Scan", format: .jpeg, size: CGSize(width: 200, height: 300)))
        for (name, document) in try writeAndReopen() {
            XCTAssertEqual(document.pageCount, 3, name)
            XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, ImagePage.a4Landscape, name)
            XCTAssertEqual(document.page(at: 2)?.bounds(for: .mediaBox).size, ImagePage.a4Portrait, name)
        }
    }

    func testLargeDocument() throws {
        try add(corpus.pdf(named: "Large", pages: 500))
        try plan.move([plan.pages[0].id], to: 500)
        for (name, document) in try writeAndReopen() {
            XCTAssertEqual(document.pageCount, 500, name)
            XCTAssertEqual(texts(document).first, "Large page 2", name)
            XCTAssertEqual(texts(document).last, "Large page 1", name)
        }
    }

    // MARK: Struktur bleibt erhalten

    func testLinksAndOutlineSurvive() throws {
        try add(corpus.linkedPDF())
        try plan.move([plan.pages[2].id], to: 0)            // Reihenfolge 3, 1, 2
        for (name, document) in try writeAndReopen() {
            let link = try XCTUnwrap(document.page(at: 1)?.annotations.first { $0.type == "Link" }, name)
            XCTAssertEqual(linkTarget(link).map(document.index(for:)), 0, name)

            let external = try XCTUnwrap(document.page(at: 2)?.annotations.first { $0.type == "Link" }, name)
            XCTAssertEqual(external.url ?? (external.action as? PDFActionURL)?.url, TestCorpus.externalLink, name)

            let root = try XCTUnwrap(document.outlineRoot, name)
            let targets = (0..<root.numberOfChildren).map {
                root.child(at: $0)?.destination?.page.map(document.index(for:))
            }
            XCTAssertEqual(targets, [1, 2, 0], name)
        }
    }

    func testFormFieldsSurvive() throws {
        try add(corpus.formPDF())
        for (name, document) in try writeAndReopen() {
            let widgets = document.page(at: 0)?.annotations.filter { $0.type == "Widget" } ?? []
            let byName = Dictionary(uniqueKeysWithValues: widgets.compactMap { w in w.fieldName.map { ($0, w) } })
            XCTAssertEqual(byName["name"]?.widgetStringValue, "Jane Doe", name)
            XCTAssertEqual(byName["agree"]?.buttonWidgetState, .onState, name)
        }
    }

    /// Die Felder müssen im Formularverzeichnis der neuen Datei stehen, sonst sind sie nicht mehr ausfüllbar.
    func testFormFieldsStayFillable() throws {
        try add(corpus.pdf(named: "Cover", pages: 1))
        try add(corpus.formPDF())
        for entry in writers {
            let url = corpus.url("Fillable-\(entry.name).pdf")
            try entry.writer.compose(plan, contents: contents, to: url, options: WriteOptions())
            let check = { XCTAssertEqual(FormFields.names(at: url, password: nil), ["name", "agree"], entry.name) }
            if entry.writer is PDFKitWriter {
                // Bekannter Fehler: PlanAssembler kopiert in ein neues PDFDocument, dabei geht /AcroForm verloren.
                // Behoben mit dem qpdf-Writer (M1b); bis dahin lehnt die Prüf-Pipeline solche Dateien ab.
                XCTExpectFailure("PDFKitWriter verliert /AcroForm", options: .nonStrict()) { check() }
            } else {
                check()
            }
        }
    }

    func testMixedScriptTextSurvives() throws {
        try add(corpus.mixedScriptPDF())
        for (name, document) in try writeAndReopen() {
            let text = try XCTUnwrap(document.page(at: 0)?.string, name)
            XCTAssertTrue(text.contains("office affinity ffi"), name)
            XCTAssertTrue(text.contains("Grüße aus Köln"), name)
        }
    }

    func testMetadata() throws {
        try add(corpus.pdf(named: "Contract", pages: 1))
        for (name, document) in try writeAndReopen() {
            let attributes = document.documentAttributes ?? [:]
            XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Contract", name)
            XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "PDF to me", name)
        }
    }

    // MARK: Passwörter

    /// Eine geschützte Quelle wird entsperrt gelesen; ohne Option ist das Ergebnis ungeschützt.
    func testEncryptedSourceWithoutOutputPassword() throws {
        try add(corpus.encryptedPDF(password: "test-password"), password: "test-password")
        for (name, document) in try writeAndReopen() {
            XCTAssertFalse(document.isEncrypted, name)
            XCTAssertEqual(texts(document), ["Encrypted page 1", "Encrypted page 2"], name)
        }
    }

    func testOutputPassword() throws {
        try add(corpus.pdf(named: "A", pages: 1))
        for writer in writers {
            let url = corpus.url("Protected-\(writer.name).pdf")
            try writer.writer.compose(plan, contents: contents, to: url, options: WriteOptions(password: "out-pw"))
            let document = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertTrue(document.isLocked, writer.name)
            XCTAssertFalse(document.unlock(withPassword: "wrong"), writer.name)
            XCTAssertTrue(document.unlock(withPassword: "out-pw"), writer.name)
            XCTAssertEqual(texts(document), ["A page 1"], writer.name)
        }
    }

    // MARK: Garantien

    /// Die Quellen sind nach dem Schreiben bytegleich.
    func testSourcesStayByteIdentical() throws {
        let urls = [try corpus.linkedPDF(), try corpus.formPDF(), try corpus.image(named: "P", format: .png)]
        let before = try urls.map { try Data(contentsOf: $0) }
        for url in urls { try add(url) }
        try plan.rotate(plan.pages.map(\.id), by: .half)
        try plan.move([plan.pages[0].id], to: plan.pages.count)
        _ = try writeAndReopen()
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
    }

    func testNeverOverwrites() throws {
        try add(corpus.pdf(named: "A", pages: 1))
        let existing = try corpus.pdf(named: "Existing", pages: 2)
        let bytes = try Data(contentsOf: existing)
        for writer in writers {
            XCTAssertThrowsError(try writer.writer.compose(plan, contents: contents, to: existing, options: .init())) {
                XCTAssertEqual($0 as? WriterError, .destinationExists(fileName: "Existing.pdf"), writer.name)
            }
        }
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
    }

    func testEmptyPlanIsNotWritten() throws {
        try add(corpus.pdf(named: "A", pages: 1))
        try plan.remove(plan.pages.map(\.id))
        for writer in writers {
            let url = corpus.url("Empty-\(writer.name).pdf")
            XCTAssertThrowsError(try writer.writer.compose(plan, contents: contents, to: url, options: .init())) {
                XCTAssertEqual($0 as? WriterError, .noPages, writer.name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testCapabilities() {
        XCTAssertTrue(PDFKitWriter().capabilities.contains(.pageOperations))
    }
}
