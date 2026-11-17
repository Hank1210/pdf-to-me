import XCTest
@testable import PDFToMeCore

// Hilfen für die Modell-Tests: Quellen ohne echte Dateien.
private func pdfSource(pages: Int = 3, name: String = "Contract.pdf", password: String? = nil) -> SourceFile {
    SourceFile(
        kind: .pdf, displayName: name, bookmark: Data([1, 2, 3]),
        sha256: String(repeating: "a", count: 64), pageCount: pages, password: password)
}

private func imageSource() -> SourceFile {
    SourceFile(
        kind: .image, displayName: "Photo.heic", bookmark: Data([4, 5]),
        sha256: String(repeating: "b", count: 64), pageCount: 1)
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

final class RotationTests: XCTestCase {
    func testInitFromDegreesNormalizes() {
        XCTAssertEqual(Rotation(degrees: 0), Rotation.none)
        XCTAssertEqual(Rotation(degrees: 90), .quarter)
        XCTAssertEqual(Rotation(degrees: 360), Rotation.none)
        XCTAssertEqual(Rotation(degrees: 450), .quarter)
        XCTAssertEqual(Rotation(degrees: -90), .threeQuarters)
        XCTAssertEqual(Rotation(degrees: -540), .half)
    }

    func testInitRejectsNonQuarterTurns() {
        XCTAssertNil(Rotation(degrees: 45))
        XCTAssertNil(Rotation(degrees: -1))
    }

    func testRotatedByAndInverse() {
        XCTAssertEqual(Rotation.quarter.rotated(by: .quarter), .half)
        XCTAssertEqual(Rotation.threeQuarters.rotated(by: .half), .quarter)
        for rotation in Rotation.allCases {
            XCTAssertEqual(rotation.rotated(by: rotation.inverse), Rotation.none, "\(rotation)")
        }
    }

    func testDecodingRejectsInvalidDegrees() {
        XCTAssertThrowsError(try JSONDecoder().decode([Rotation].self, from: Data("[45]".utf8)))
        XCTAssertEqual(try JSONDecoder().decode([Rotation].self, from: Data("[270]".utf8)), [.threeQuarters])
    }
}

final class SourceFileTests: XCTestCase {
    func testRoundTripKeepsEverythingButPassword() throws {
        let source = pdfSource(password: "secret")
        let decoded = try roundTrip(source)
        XCTAssertNil(decoded.password)
        var expected = source
        expected.password = nil
        XCTAssertEqual(decoded, expected)
    }

    /// Das Passwort darf nie in eine Sitzungsdatei gelangen, auch nicht in verschachtelten Strukturen.
    func testPasswordIsNeverEncoded() throws {
        let source = pdfSource(password: "secret-7f3a")
        let plan = try DocumentPlan(source: source)
        for data in [try JSONEncoder().encode(source), try JSONEncoder().encode(plan),
                     try PropertyListEncoder().encode(plan)] {
            XCTAssertNil(data.range(of: Data("secret-7f3a".utf8)))
            XCTAssertNil(data.range(of: Data("password".utf8)))
        }
    }

    /// Protokolle und Debug-Ausgaben dürfen das Passwort nicht zeigen.
    func testPasswordIsNeverPrinted() {
        let source = pdfSource(password: "secret-7f3a")
        var dumped = ""
        dump(source, to: &dumped)
        for text in ["\(source)", String(describing: source), String(reflecting: source), dumped] {
            XCTAssertFalse(text.contains("secret-7f3a"), text)
            XCTAssertTrue(text.contains("hasPassword"), text)
        }
    }
}

final class DocumentPlanTests: XCTestCase {
    func testPlanFromSourceContainsAllPagesInOrder() throws {
        let source = pdfSource(pages: 4)
        let plan = try DocumentPlan(source: source)
        XCTAssertEqual(plan.sources, [source])
        XCTAssertEqual(plan.pages.map(\.index), [0, 1, 2, 3])
        XCTAssertTrue(plan.pages.allSatisfy { $0.source == source.id && $0.rotation == .none })
        XCTAssertEqual(Set(plan.pages.map(\.id)).count, 4)
    }

    func testPlanFromImageHasOnePage() throws {
        let plan = try DocumentPlan(source: imageSource())
        XCTAssertEqual(plan.pages.map(\.index), [0])
    }

    func testEmptyPlanIsValid() throws {
        let plan = try DocumentPlan(sources: [], pages: [])
        XCTAssertTrue(plan.pages.isEmpty)
    }

    func testLookups() throws {
        let a = pdfSource(pages: 2, name: "A.pdf")
        let b = imageSource()
        let pages = [PageRef(source: b.id, index: 0), PageRef(source: a.id, index: 1)]
        let plan = try DocumentPlan(sources: [a, b], pages: pages)

        XCTAssertEqual(plan.source(withID: a.id), a)
        XCTAssertEqual(plan.source(of: pages[0]), b)
        XCTAssertEqual(plan.page(withID: pages[1].id), pages[1])
        XCTAssertEqual(plan.position(of: pages[1].id), 1)
        XCTAssertNil(plan.position(of: UUID()))
        XCTAssertNil(plan.source(withID: UUID()))
    }

    func testRoundTrip() throws {
        let a = pdfSource(pages: 3)
        let b = imageSource()
        let plan = try DocumentPlan(sources: [a, b], pages: [
            PageRef(source: a.id, index: 2, rotation: .quarter),
            PageRef(source: b.id, index: 0),
            PageRef(source: a.id, index: 0, rotation: .threeQuarters),
        ])
        XCTAssertEqual(try roundTrip(plan), plan)
    }

    // MARK: Ungültige Pläne

    func testRejectsDuplicateSource() {
        let source = pdfSource()
        XCTAssertThrowsError(try DocumentPlan(sources: [source, source], pages: [])) {
            XCTAssertEqual($0 as? DocumentPlanError, .duplicateSource(source.id))
        }
    }

    func testRejectsDuplicatePage() {
        let source = pdfSource()
        let page = PageRef(source: source.id, index: 0)
        XCTAssertThrowsError(try DocumentPlan(sources: [source], pages: [page, page])) {
            XCTAssertEqual($0 as? DocumentPlanError, .duplicatePage(page.id))
        }
    }

    /// Dieselbe Quellseite darf mehrfach vorkommen, solange jede Seite eine eigene Kennung hat.
    func testAllowsSameSourcePageTwice() throws {
        let source = pdfSource()
        let plan = try DocumentPlan(sources: [source], pages: [
            PageRef(source: source.id, index: 0), PageRef(source: source.id, index: 0),
        ])
        XCTAssertEqual(plan.pages.count, 2)
    }

    func testRejectsUnknownSource() {
        let page = PageRef(source: UUID(), index: 0)
        XCTAssertThrowsError(try DocumentPlan(sources: [pdfSource()], pages: [page])) {
            XCTAssertEqual($0 as? DocumentPlanError, .unknownSource(page: page.id, source: page.source))
        }
    }

    func testRejectsPageIndexOutOfRange() {
        let source = pdfSource(pages: 3)
        for index in [-1, 3] {
            let page = PageRef(source: source.id, index: index)
            XCTAssertThrowsError(try DocumentPlan(sources: [source], pages: [page])) {
                XCTAssertEqual($0 as? DocumentPlanError,
                               .pageIndexOutOfRange(page: page.id, index: index, pageCount: 3))
            }
        }
        let image = imageSource()
        XCTAssertThrowsError(try DocumentPlan(sources: [image], pages: [PageRef(source: image.id, index: 1)]))
    }

    func testRejectsInvalidPageCount() {
        var emptyPDF = pdfSource()
        emptyPDF.pageCount = 0
        var multiPageImage = imageSource()
        multiPageImage.pageCount = 2
        for source in [emptyPDF, multiPageImage] {
            XCTAssertThrowsError(try DocumentPlan(sources: [source], pages: [])) {
                XCTAssertEqual($0 as? DocumentPlanError,
                               .invalidPageCount(source: source.id, pageCount: source.pageCount))
            }
        }
    }

    /// Eine beschädigte Sitzungsdatei wird beim Dekodieren abgelehnt, nicht halb übernommen.
    func testDecodingRejectsInconsistentPlan() throws {
        let source = pdfSource(pages: 2)
        let plan = try DocumentPlan(source: source)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var pages = try XCTUnwrap(json["pages"] as? [[String: Any]])
        pages[0]["index"] = 5
        json["pages"] = pages
        let broken = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(DocumentPlan.self, from: broken)) {
            guard case .pageIndexOutOfRange = $0 as? DocumentPlanError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testErrorsHaveMessagesInBothLanguages() {
        defer { Localization.current = .de }
        let error = DocumentPlanError.pageIndexOutOfRange(page: UUID(), index: 4, pageCount: 3)
        Localization.current = .de
        XCTAssertEqual(error.errorDescription,
                       "Eine Seite verweist auf Seite 5, die Quelldatei hat aber nur 3 Seiten.")
        Localization.current = .en
        XCTAssertEqual(error.errorDescription, "A page refers to page 5, but the source file has only 3 pages.")
    }
}
