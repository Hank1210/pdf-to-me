import XCTest
@testable import PDFToMeCore

final class PlanOperationTests: XCTestCase {
    private var source: SourceFile!
    private var plan: DocumentPlan!

    override func setUpWithError() throws {
        source = SourceFile(
            kind: .pdf, displayName: "A.pdf", bookmark: Data([1]),
            sha256: String(repeating: "a", count: 64), pageCount: 5)
        plan = try DocumentPlan(source: source)
    }

    /// Seitenindizes in der Quelle, in der Reihenfolge des Plans; zeigt die Reihenfolge kompakt.
    private var order: [Int] { plan.pages.map(\.index) }
    private func ids(_ indices: Int...) -> [PageRef.ID] { indices.map { plan.pages[$0].id } }

    private func newSource(pages: Int = 2, kind: SourceFile.Kind = .pdf) -> SourceFile {
        SourceFile(
            kind: kind, displayName: "B.pdf", bookmark: Data([2]),
            sha256: String(repeating: "b", count: 64), pageCount: pages)
    }

    // MARK: Einfügen

    func testInsertPagesOfNewSource() throws {
        let b = newSource()
        try plan.insertPages(of: b, at: 2)
        XCTAssertEqual(plan.sources.map(\.id), [source.id, b.id])
        XCTAssertEqual(plan.pages.map(\.source), [source.id, source.id, b.id, b.id, source.id, source.id, source.id])
        XCTAssertEqual(order, [0, 1, 0, 1, 2, 3, 4])

        try plan.undo()
        XCTAssertEqual(plan.sources.map(\.id), [source.id])
        XCTAssertEqual(order, [0, 1, 2, 3, 4])

        try plan.redo()
        XCTAssertEqual(plan.sources.map(\.id), [source.id, b.id])
        XCTAssertEqual(order, [0, 1, 0, 1, 2, 3, 4])
    }

    func testInsertAtStartAndEnd() throws {
        try plan.insert([PageRef(source: source.id, index: 4)], at: 0)
        try plan.insert([PageRef(source: source.id, index: 0)], at: plan.pages.count)
        XCTAssertEqual(order, [4, 0, 1, 2, 3, 4, 0])
    }

    func testInsertRejectsInvalidInputAndLeavesPlanUnchanged() throws {
        let before = plan!
        XCTAssertThrowsError(try plan.insert([PageRef(source: source.id, index: 0)], at: 6)) {
            XCTAssertEqual($0 as? DocumentPlanError, .positionOutOfRange(position: 6, count: 5))
        }
        XCTAssertThrowsError(try plan.insert([PageRef(source: UUID(), index: 0)], at: 0))
        XCTAssertThrowsError(try plan.insert([plan.pages[0]], at: 0)) {
            XCTAssertEqual($0 as? DocumentPlanError, .duplicatePage(before.pages[0].id))
        }
        XCTAssertThrowsError(try plan.insertPages(of: source, at: 0)) {
            XCTAssertEqual($0 as? DocumentPlanError, .duplicateSource(before.sources[0].id))
        }
        XCTAssertEqual(plan, before)
    }

    // MARK: Entfernen

    func testRemoveAndUndoRestoresPositions() throws {
        let before = plan.pages
        try plan.remove(ids(4, 0, 2, 2))
        XCTAssertEqual(order, [1, 3])
        try plan.undo()
        XCTAssertEqual(plan.pages, before)
        try plan.redo()
        XCTAssertEqual(order, [1, 3])
    }

    /// Entfernen lässt die Quelle stehen, auch wenn keine ihrer Seiten mehr im Plan ist.
    func testRemoveAllPagesKeepsSource() throws {
        try plan.remove(plan.pages.map(\.id))
        XCTAssertTrue(plan.pages.isEmpty)
        XCTAssertEqual(plan.sources, [source])
    }

    func testRemoveUnknownPageThrows() {
        let before = plan!
        let unknown = UUID()
        XCTAssertThrowsError(try plan.remove(ids(0) + [unknown])) {
            XCTAssertEqual($0 as? DocumentPlanError, .unknownPage(unknown))
        }
        XCTAssertEqual(plan, before)
    }

    // MARK: Verschieben

    func testMoveSinglePage() throws {
        try plan.move(ids(0), to: 3)          // vor die Seite, die an Position 3 stand
        XCTAssertEqual(order, [1, 2, 0, 3, 4])
        try plan.move(ids(4), to: 0)
        XCTAssertEqual(order, [4, 1, 2, 0, 3])
        try plan.move(ids(0), to: 5)          // ans Ende
        XCTAssertEqual(order, [1, 2, 0, 3, 4])
    }

    /// Verschobene Seiten behalten ihre Reihenfolge untereinander, auch wenn die Auswahl anders sortiert ist.
    func testMoveSelectionKeepsRelativeOrder() throws {
        try plan.move(ids(3, 0), to: 2)
        XCTAssertEqual(order, [1, 0, 3, 2, 4])
        try plan.undo()
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
        try plan.move(ids(4, 1), to: 0)
        XCTAssertEqual(order, [1, 4, 0, 2, 3])
    }

    func testMoveWithoutEffectCreatesNoUndoStep() throws {
        try plan.move(ids(1), to: 1)
        try plan.move(ids(1), to: 2)
        try plan.move(ids(3, 4), to: 5)
        try plan.move([], to: 0)
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
        XCTAssertFalse(plan.canUndo)
    }

    func testMoveRejectsInvalidPosition() {
        XCTAssertThrowsError(try plan.move(ids(0), to: 6)) {
            XCTAssertEqual($0 as? DocumentPlanError, .positionOutOfRange(position: 6, count: 5))
        }
        XCTAssertThrowsError(try plan.move(ids(0), to: -1))
    }

    // MARK: Drehen

    func testRotateAndUndo() throws {
        try plan.rotate(ids(1, 3, 3), by: .quarter)
        try plan.rotate(ids(3), by: .half)
        XCTAssertEqual(plan.pages.map(\.rotation), [.none, .quarter, .none, .threeQuarters, .none])
        try plan.undo()
        XCTAssertEqual(plan.pages.map(\.rotation), [.none, .quarter, .none, .quarter, .none])
        try plan.undo()
        XCTAssertTrue(plan.pages.allSatisfy { $0.rotation == .none })
    }

    func testRotateByNoneCreatesNoUndoStep() throws {
        try plan.rotate(ids(0), by: .none)
        try plan.rotate([], by: .quarter)
        XCTAssertFalse(plan.canUndo)
    }

    // MARK: Undo und Redo

    func testNewOperationClearsRedo() throws {
        try plan.rotate(ids(0), by: .quarter)
        try plan.undo()
        XCTAssertTrue(plan.canRedo)
        try plan.remove(ids(1))
        XCTAssertFalse(plan.canRedo)
        XCTAssertEqual(plan.undoStack.count, 1)
    }

    func testUndoRedoWithEmptyStacksDoesNothing() throws {
        let before = plan!
        try plan.undo()
        try plan.redo()
        XCTAssertEqual(plan, before)
    }

    /// Viele zufällige Operationen: Alles rückgängig ergibt den Anfangszustand, alles wiederholt den Endzustand.
    func testRandomOperationsUndoAndRedoCompletely() throws {
        var generator = SeededGenerator(seed: 42)
        let start = plan!
        var states = [plan.pages]
        for _ in 0..<300 {
            let count = plan.pages.count
            let selection = plan.pages.filter { _ in Bool.random(using: &generator) }.map(\.id)
            switch Int.random(in: 0..<5, using: &generator) {
            case 4:
                try plan.recognizeText(Array(selection.prefix(3)))
            case 0:
                let page = PageRef(source: source.id, index: Int.random(in: 0..<5, using: &generator))
                try plan.insert([page], at: Int.random(in: 0...count, using: &generator))
            case 1 where count > 3:
                try plan.remove(Array(selection.prefix(2)))
            case 2:
                try plan.move(selection, to: Int.random(in: 0...count, using: &generator))
            default:
                try plan.rotate(selection, by: Rotation.allCases.randomElement(using: &generator)!)
            }
            if plan.pages != states.last { states.append(plan.pages) }
        }
        let end = plan!
        XCTAssertGreaterThan(plan.undoStack.count, 100)

        while plan.canUndo { try plan.undo() }
        XCTAssertEqual(plan.pages, start.pages)
        XCTAssertEqual(plan.sources, start.sources)

        while plan.canRedo { try plan.redo() }
        XCTAssertEqual(plan.pages, end.pages)
        XCTAssertEqual(plan.undoStack, end.undoStack)
    }

    // MARK: Texterkennung vormerken

    func testRecognizeTextAndUndo() throws {
        try plan.recognizeText(ids(1, 3))
        XCTAssertEqual(plan.pages.map(\.recognizesText), [false, true, false, true, false])
        try plan.undo()
        XCTAssertFalse(plan.pages.contains { $0.recognizesText })
        try plan.redo()
        XCTAssertEqual(plan.pages.map(\.recognizesText), [false, true, false, true, false])
    }

    /// Schon vorgemerkte Seiten zählen nicht; ändert sich nichts, gibt es keinen Undo-Schritt.
    func testRecognizeTextSkipsMarkedPages() throws {
        try plan.recognizeText(ids(1))
        try plan.recognizeText(ids(1, 2, 2))
        XCTAssertEqual(plan.undoStack.last, .recognizeText(ids: ids(2)))
        let steps = plan.undoStack.count
        try plan.recognizeText(ids(1, 2))
        try plan.recognizeText([])
        XCTAssertEqual(plan.undoStack.count, steps)
    }

    func testRecognizeTextRejectsUnknownPage() {
        let before = plan!
        XCTAssertThrowsError(try plan.recognizeText([UUID()]))
        XCTAssertEqual(plan, before)
    }

    /// Das Merkmal gehört zur Seite: Es wandert beim Verschieben mit, bleibt beim Drehen und beim Extrahieren.
    func testRecognizeTextFollowsThePage() throws {
        try plan.recognizeText(ids(4))
        let marked = plan.pages[4].id
        try plan.move([marked], to: 0)
        try plan.rotate([marked], by: .quarter)
        XCTAssertTrue(plan.pages[0].recognizesText)
        let part = try plan.extracting([marked, plan.pages[1].id])
        XCTAssertEqual(part.pages.map(\.recognizesText), [true, false])
        XCTAssertEqual(part.pages[0].rotation, .quarter)
    }

    /// Eine gesicherte Operation, die nicht mehr zum Plan passt, wird abgelehnt.
    func testRecognizeTextHistoryMismatch() throws {
        try plan.recognizeText(ids(0))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        var pages = json["pages"] as! [[String: Any]]
        pages[0]["recognizesText"] = false
        json["pages"] = pages
        var damaged = try JSONDecoder().decode(DocumentPlan.self, from: JSONSerialization.data(withJSONObject: json))
        let before = damaged
        XCTAssertThrowsError(try damaged.undo()) { XCTAssertEqual($0 as? DocumentPlanError, .historyMismatch) }
        XCTAssertEqual(damaged, before)
    }

    // MARK: Sitzung

    /// Undo und Redo funktionieren auch nach dem Sichern und Laden der Sitzung.
    func testHistorySurvivesRoundTrip() throws {
        try plan.insertPages(of: newSource(), at: 1)
        try plan.move(ids(0), to: 7)
        try plan.rotate(ids(2), by: .threeQuarters)
        try plan.undo()

        var restored = try JSONDecoder().decode(DocumentPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(restored, plan)

        try restored.undo()
        try restored.undo()
        XCTAssertEqual(restored.pages.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(restored.sources.map(\.id), [source.id])
        try restored.redo()
        try restored.redo()
        try restored.redo()
        XCTAssertEqual(restored.pages.map(\.rotation)[2], .threeQuarters)
    }

    /// Eine gesicherte Operation, die nicht zum Plan passt, schlägt fehl und lässt den Plan unverändert.
    func testMismatchingHistoryThrowsAndLeavesPlanUnchanged() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        let foreignPage = UUID().uuidString
        let samples: [(stack: String, operation: [String: Any], error: DocumentPlanError?)] = [
            ("undoStack", ["rotate": ["ids": [foreignPage], "by": 90]], .unknownPage(UUID(uuidString: foreignPage)!)),
            ("undoStack", ["remove": ["pages": [], "positions": [9]]], .historyMismatch),
            ("redoStack", ["move": ["ids": [foreignPage], "from": [0], "to": 3]], .historyMismatch),
            ("redoStack", ["insert": ["pages": [], "position": 99, "addedSources": []]],
             .positionOutOfRange(position: 99, count: 5)),
        ]
        for sample in samples {
            json["undoStack"] = []
            json["redoStack"] = []
            json[sample.stack] = [sample.operation]
            var corrupt = try JSONDecoder().decode(
                DocumentPlan.self, from: JSONSerialization.data(withJSONObject: json))
            let unchanged = corrupt
            XCTAssertThrowsError(try (sample.stack == "undoStack" ? corrupt.undo() : corrupt.redo())) {
                XCTAssertEqual($0 as? DocumentPlanError, sample.error, "\(sample.operation)")
            }
            XCTAssertEqual(corrupt, unchanged)
        }
    }

    // MARK: Extrahieren

    func testExtractingKeepsOrderRotationAndNeededSources() throws {
        let b = newSource()
        try plan.insertPages(of: b, at: 5)
        try plan.rotate(ids(3), by: .quarter)
        let extracted = try plan.extracting(ids(3, 1))

        XCTAssertNotEqual(extracted.id, plan.id)
        XCTAssertEqual(extracted.pages.map(\.index), [1, 3])
        XCTAssertEqual(extracted.pages.map(\.rotation), [.none, .quarter])
        XCTAssertEqual(extracted.sources, [source])
        XCTAssertTrue(Set(extracted.pages.map(\.id)).isDisjoint(with: plan.pages.map(\.id)))
        XCTAssertFalse(extracted.canUndo)

        let mixed = try plan.extracting(ids(6, 0))
        XCTAssertEqual(mixed.sources.map(\.id), [source.id, b.id])
        XCTAssertEqual(mixed.pages.map(\.source), [source.id, b.id])
    }

    func testExtractingRejectsEmptyOrUnknownSelection() {
        XCTAssertThrowsError(try plan.extracting([])) {
            XCTAssertEqual($0 as? DocumentPlanError, .emptySelection)
        }
        XCTAssertThrowsError(try plan.extracting([UUID()]))
    }
}

/// Reproduzierbarer Zufallsgenerator für Tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
