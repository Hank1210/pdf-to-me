import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import PDFToMeCore

final class PlanAssemblerTests: XCTestCase {
    private var corpus: TestCorpus!
    private var plan: DocumentPlan!
    private var contents: [SourceFile.ID: LoadedSource.Content] = [:]

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    /// Öffnet eine Datei und macht sie zum Plan (erste Quelle) oder fügt sie am Ende an.
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

    private func assemble() throws -> AssembledDocument {
        try PlanAssembler.assemble(plan, contents: contents)
    }

    private func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func sourceDocument(_ source: SourceFile) throws -> PDFDocument {
        guard case let .pdf(document) = contents[source.id] else { throw XCTSkip("no PDF") }
        return document
    }

    // MARK: Reihenfolge und Drehung

    func testFollowsPlanOrderAndRotation() throws {
        let a = try add(corpus.pdf(named: "A", pages: 3))
        try add(corpus.pdf(named: "B", pages: 2))
        try plan.move([plan.pages[4].id], to: 0)          // B2 an den Anfang
        try plan.remove([plan.pages[2].id])                // A2 weg
        try plan.rotate([plan.pages[0].id], by: .quarter)

        let assembled = try assemble()
        XCTAssertEqual(texts(assembled.document), ["B page 2", "A page 1", "A page 3", "B page 1"])
        XCTAssertEqual(assembled.pageIDs, plan.pages.map(\.id))
        XCTAssertEqual(assembled.document.page(at: 0)?.rotation, 90)
        XCTAssertEqual(assembled.document.page(at: 1)?.rotation, 0)
        XCTAssertEqual(assembled.pageID(of: try XCTUnwrap(assembled.document.page(at: 2))), plan.pages[2].id)

        // Die Quelle bleibt unverändert.
        let source = try sourceDocument(a)
        XCTAssertEqual(source.pageCount, 3)
        XCTAssertEqual(source.page(at: 0)?.rotation, 0)
    }

    func testSamePageTwice() throws {
        let a = try add(corpus.pdf(named: "A", pages: 2))
        try plan.insert([PageRef(source: a.id, index: 0)], at: 2)
        try plan.rotate([plan.pages[2].id], by: .half)
        let document = try assemble().document
        XCTAssertEqual(texts(document), ["A page 1", "A page 2", "A page 1"])
        XCTAssertEqual(document.page(at: 0)?.rotation, 0)
        XCTAssertEqual(document.page(at: 2)?.rotation, 180)
    }

    func testEmptyPlan() throws {
        try add(corpus.pdf(named: "A", pages: 1))
        try plan.remove(plan.pages.map(\.id))
        let assembled = try assemble()
        XCTAssertEqual(assembled.document.pageCount, 0)
        XCTAssertNil(assembled.document.outlineRoot)
    }

    func testEncryptedSource() throws {
        try add(corpus.encryptedPDF(password: "test-password"), password: "test-password")
        XCTAssertEqual(texts(try assemble().document), ["Encrypted page 1", "Encrypted page 2"])
    }

    func testMissingContentThrows() throws {
        let a = try add(corpus.pdf(named: "A", pages: 1))
        contents[a.id] = nil
        XCTAssertThrowsError(try assemble()) {
            XCTAssertEqual($0 as? AssemblyError, .missingContent(fileName: "A.pdf"))
        }
    }

    // MARK: Links und Formulare

    func testInternalLinksPointIntoNewDocument() throws {
        let linked = try add(corpus.linkedPDF())
        try plan.move([plan.pages[2].id], to: 0)          // Seite 3 nach vorn: Link von Seite 1 zeigt auf Position 0
        let document = try assemble().document

        let link = try XCTUnwrap(document.page(at: 1)?.annotations.first { $0.type == "Link" })
        let target = try XCTUnwrap((link.action as? PDFActionGoTo)?.destination.page)
        XCTAssertTrue(target.document === document)
        XCTAssertEqual(document.index(for: target), 0)

        let external = try XCTUnwrap(document.page(at: 2)?.annotations.first { $0.type == "Link" })
        XCTAssertEqual(external.url ?? (external.action as? PDFActionURL)?.url, TestCorpus.externalLink)

        // Die Links der Quelle zeigen weiter in die Quelle.
        let source = try sourceDocument(linked)
        let sourceLink = try XCTUnwrap(source.page(at: 0)?.annotations.first { $0.type == "Link" })
        let sourceTarget = (sourceLink.action as? PDFActionGoTo)?.destination.page ?? sourceLink.destination?.page
        XCTAssertTrue(sourceTarget?.document === source)
        XCTAssertEqual(sourceTarget.map(source.index(for:)), 2)
    }

    /// PDFKit teilt zwischen kopierten Seiten intern Daten mit dem Original. Die geladenen Quellen werden für jede
    /// Vorschau wiederverwendet; deshalb muss wiederholtes Zusammensetzen dasselbe Ergebnis liefern und die Quelle
    /// unverändert lassen.
    func testRepeatedAssemblyLeavesSourcesUntouched() throws {
        let linked = try add(corpus.linkedPDF())
        try add(corpus.formPDF())
        try plan.move([plan.pages[2].id], to: 0)

        for round in 1...3 {
            let document = try assemble().document
            let link = try XCTUnwrap(document.page(at: 1)?.annotations.first { $0.type == "Link" }, "round \(round)")
            let target = (link.action as? PDFActionGoTo)?.destination.page
            XCTAssertEqual(target.map(document.index(for:)), 0, "round \(round)")
            XCTAssertEqual(document.page(at: 3)?.annotations.filter { $0.type == "Widget" }.count, 2)
            XCTAssertNotNil(document.outlineRoot)
        }

        let source = try sourceDocument(linked)
        let sourceLink = try XCTUnwrap(source.page(at: 0)?.annotations.first { $0.type == "Link" })
        let sourceTarget = (sourceLink.action as? PDFActionGoTo)?.destination.page ?? sourceLink.destination?.page
        XCTAssertEqual(sourceTarget.map(source.index(for:)), 2)
        XCTAssertEqual(source.page(at: 0)?.annotations.count, 1)
        XCTAssertEqual(source.outlineRoot?.numberOfChildren, 3)
    }

    /// Fehlt das Ziel eines internen Links im Ergebnis, wird der Link entfernt statt ins Leere zu zeigen.
    func testLinkToRemovedPageIsDropped() throws {
        try add(corpus.linkedPDF())
        try plan.remove([plan.pages[2].id])
        let document = try assemble().document
        XCTAssertTrue(document.page(at: 0)?.annotations.filter { $0.type == "Link" }.isEmpty == true)
        XCTAssertEqual(document.page(at: 1)?.annotations.filter { $0.type == "Link" }.count, 1)   // extern bleibt
    }

    func testFormFieldsSurvive() throws {
        try add(corpus.formPDF())
        let widgets = try XCTUnwrap(try assemble().document.page(at: 0)?.annotations.filter { $0.type == "Widget" })
        let byName = Dictionary(uniqueKeysWithValues: widgets.compactMap { w in w.fieldName.map { ($0, w) } })
        XCTAssertEqual(byName["name"]?.widgetStringValue, "Jane Doe")
        XCTAssertEqual(byName["agree"]?.buttonWidgetState, .onState)
    }

    // MARK: Inhaltsverzeichnis

    func testOutlineOfSingleSource() throws {
        try add(corpus.linkedPDF())
        try plan.move([plan.pages[0].id], to: 3)          // Reihenfolge 2, 3, 1
        let document = try assemble().document
        let root = try XCTUnwrap(document.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 3)
        let targets = (0..<3).map { root.child(at: $0)?.destination?.page.map(document.index(for:)) }
        XCTAssertEqual(targets, [2, 0, 1])
        XCTAssertEqual(root.child(at: 0)?.label, "Chapter 1")
    }

    func testOutlineDropsEntriesForRemovedPages() throws {
        try add(corpus.linkedPDF())
        try plan.remove([plan.pages[1].id])
        let root = try XCTUnwrap(try assemble().document.outlineRoot)
        XCTAssertEqual((0..<root.numberOfChildren).map { root.child(at: $0)?.label }, ["Chapter 1", "Chapter 3"])
    }

    func testOutlinesOfSeveralSourcesAreGrouped() throws {
        try add(corpus.linkedPDF(named: "First"))
        try add(corpus.pdf(named: "Plain", pages: 1))     // ohne Inhaltsverzeichnis
        try add(corpus.linkedPDF(named: "Second"))
        let document = try assemble().document
        let root = try XCTUnwrap(document.outlineRoot)
        XCTAssertEqual((0..<root.numberOfChildren).map { root.child(at: $0)?.label }, ["First.pdf", "Second.pdf"])
        let second = try XCTUnwrap(root.child(at: 1))
        XCTAssertEqual(second.destination?.page.map(document.index(for:)), 4)
        XCTAssertEqual(second.numberOfChildren, 3)
        XCTAssertEqual(second.child(at: 2)?.destination?.page.map(document.index(for:)), 6)
    }

    // MARK: Bilder

    func testImagePageSizeFollowsAspectRatio() throws {
        try add(corpus.image(named: "Wide", format: .png, size: CGSize(width: 300, height: 200)))
        try add(corpus.image(named: "Tall", format: .jpeg, size: CGSize(width: 200, height: 300)))
        try add(corpus.image(named: "Square", format: .heic, size: CGSize(width: 100, height: 100)))
        let document = try assemble().document
        let sizes = (0..<3).map { document.page(at: $0)!.bounds(for: .mediaBox).size }
        XCTAssertEqual(sizes, [ImagePage.a4Landscape, ImagePage.a4Portrait, ImagePage.a4Portrait])
    }

    /// Das Bild füllt die Seite in einer Richtung aus, mittig und unverzerrt; die Markierung oben links bleibt oben
    /// links.
    func testImageIsFittedAndCentered() throws {
        try add(corpus.image(named: "Wide", format: .png, size: CGSize(width: 300, height: 200)))
        let page = try XCTUnwrap(try assemble().document.page(at: 0))
        let pixels = try Pixels(page)
        // 300 × 200 in 842 × 595: Faktor 2,807, Bildhöhe 561, weißer Rand oben und unten je 17 Punkte.
        XCTAssertTrue(pixels.isWhite(at: CGPoint(x: 421, y: 5)), "top margin")
        XCTAssertTrue(pixels.isWhite(at: CGPoint(x: 421, y: 590)), "bottom margin")
        XCTAssertTrue(pixels.isBlue(at: CGPoint(x: 421, y: 297)), "center")
        XCTAssertTrue(pixels.isYellow(at: CGPoint(x: 30, y: 60)), "marker top left")
        XCTAssertTrue(pixels.isBlue(at: CGPoint(x: 812, y: 60)), "no marker top right")
    }

    /// Ein Foto mit EXIF-Ausrichtung „rechts“ (um 90° gedreht gespeichert) erscheint aufrecht.
    func testImageOrientationIsApplied() throws {
        let url = corpus.url("Rotated.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try TestCorpus.makeImage(size: CGSize(width: 300, height: 200)),
            [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        try add(url)
        let page = try XCTUnwrap(try assemble().document.page(at: 0))
        // Aufgerichtet ist das Bild 200 × 300, also hoch. Die Markierung oben links wandert nach oben rechts.
        XCTAssertEqual(page.bounds(for: .mediaBox).size, ImagePage.a4Portrait)
        let pixels = try Pixels(page)
        XCTAssertTrue(pixels.isYellow(at: CGPoint(x: 560, y: 60)), "marker top right")
        XCTAssertTrue(pixels.isBlue(at: CGPoint(x: 40, y: 60)), "no marker top left")
    }

    func testSameImageTwiceGivesIndependentPages() throws {
        let image = try add(corpus.image(named: "Photo", format: .png))
        try plan.insert([PageRef(source: image.id, index: 0, rotation: .quarter)], at: 1)
        let document = try assemble().document
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.rotation, 0)
        XCTAssertEqual(document.page(at: 1)?.rotation, 90)
    }

    // MARK: Leistung

    /// README: Ein Dokument mit 500 Seiten öffnet sich in unter 2 Sekunden.
    func testFiveHundredPagesOpenQuickly() throws {
        let url = try corpus.pdf(named: "Large", pages: 500)
        let start = Date()
        try add(url)
        let document = try assemble().document
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(document.pageCount, 500)
        XCTAssertLessThan(elapsed, 2, "open and assemble took \(elapsed) s")
    }
}

/// Rendert eine Seite in Seitenpunkten (1 Pixel je Punkt) und liest Farben; Ursprung oben links.
private struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ page: PDFPage) throws {
        let size = page.bounds(for: .mediaBox).size
        let (width, height) = (Int(size.width), Int(size.height))
        (self.width, self.height) = (width, height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let rendered: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard rendered else { throw XCTSkip("no bitmap context") }
        bytes = buffer
    }

    private func rgb(at point: CGPoint) -> (Int, Int, Int) {
        // Der Bitmap-Kontext speichert die oberste Zeile zuerst.
        let offset = (Int(point.y) * width + Int(point.x)) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func isWhite(at point: CGPoint) -> Bool { let (r, g, b) = rgb(at: point); return r > 240 && g > 240 && b > 240 }
    func isBlue(at point: CGPoint) -> Bool { let (r, _, b) = rgb(at: point); return b > 150 && r < 100 }
    func isYellow(at point: CGPoint) -> Bool { let (r, g, b) = rgb(at: point); return r > 200 && g > 150 && b < 80 }
}
