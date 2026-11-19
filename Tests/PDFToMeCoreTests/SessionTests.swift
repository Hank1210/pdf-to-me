import DocKit
import PDFKit
import XCTest
@testable import PDFToMeCore

final class SessionStoreTests: XCTestCase {
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

    private func samplePlan(pages: Int = 3) throws -> DocumentPlan {
        let source = SourceFile(
            kind: .pdf, displayName: "A.pdf", bookmark: Data([1]), sha256: "abc", pageCount: pages,
            password: "secret-7f3a")
        var plan = try DocumentPlan(source: source)
        try plan.rotate([plan.pages[0].id], by: .quarter)
        return plan
    }

    func testStandardDirectory() throws {
        let url = try SessionStore.standard().directory
        XCTAssertEqual(url.lastPathComponent, "Sessions")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "PDF to me")
    }

    func testSaveAndLoad() throws {
        let plan = try samplePlan()
        try store.save(plan)
        let loaded = try store.load(plan.id)
        XCTAssertEqual(loaded.pages, plan.pages)
        XCTAssertEqual(loaded.undoStack, plan.undoStack)
        XCTAssertNil(loaded.sources[0].password)
    }

    func testFileHasNoPasswordAndIsPrivate() throws {
        let plan = try samplePlan()
        try store.save(plan)
        let url = store.url(for: plan.id)
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("secret-7f3a".utf8)))
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions]
        XCTAssertEqual(folderMode as? Int, 0o700)
    }

    /// Gesichert wird nur, welche Seiten Text bekommen sollen, nie der erkannte Text selbst.
    func testRecognizedTextIsNeverSaved() throws {
        var plan = try samplePlan()
        try plan.recognizeText([plan.pages[1].id])
        let cache = TextRecognitionCache()
        let key = TextRecognitionCache.Key(source: plan.sources[0], page: plan.pages[1])
        cache[key] = RecognizedPage(lines: [RecognizedLine(text: "Kontostand 4711", box: .zero)])
        try store.save(plan)
        let data = try Data(contentsOf: store.url(for: plan.id))
        XCTAssertNil(data.range(of: Data("Kontostand".utf8)))
        XCTAssertEqual(try store.load(plan.id).pages.map(\.recognizesText), [false, true, false])
    }

    /// Sitzungsdateien von Version 1.0 haben das Feld `recognizesText` noch nicht.
    func testSessionFromVersion1Loads() throws {
        let plan = try samplePlan()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        json["pages"] = (json["pages"] as! [[String: Any]]).map { page in
            var page = page
            page.removeValue(forKey: "recognizesText")
            return page
        }
        let loaded = try JSONDecoder().decode(DocumentPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.pages.map(\.recognizesText), [false, false, false])
        XCTAssertEqual(loaded.pages.map(\.rotation), plan.pages.map(\.rotation))
    }

    func testSaveReplacesPreviousVersion() throws {
        var plan = try samplePlan()
        try store.save(plan)
        try plan.remove([plan.pages[1].id])
        try store.save(plan)
        XCTAssertEqual(try store.load(plan.id).pages.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 1)
    }

    func testRemove() throws {
        let plan = try samplePlan()
        try store.save(plan)
        try store.remove(plan.id)
        try store.remove(plan.id)                           // zweimal ist kein Fehler
        XCTAssertEqual(try store.loadAll().sessions, [])
    }

    func testLoadAllNewestFirstAndReportsDamagedFiles() throws {
        XCTAssertTrue(try store.loadAll().sessions.isEmpty)   // Ordner fehlt noch

        let older = try samplePlan()
        let newer = try samplePlan(pages: 2)
        try store.save(older)
        try store.save(newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: store.url(for: older.id).path)
        let damaged = store.directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: damaged)
        try Data("ignored".utf8).write(to: store.directory.appendingPathComponent("notes.txt"))

        let result = try store.loadAll()
        XCTAssertEqual(result.sessions.map(\.id), [newer.id, older.id])
        XCTAssertEqual(result.damaged.map(\.lastPathComponent), [damaged.lastPathComponent])
    }
}

final class SessionRestoreTests: XCTestCase {
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

    /// Simuliert einen Absturz: Plan sichern, alles im Speicher vergessen, aus der Datei wiederherstellen.
    private func crashAndRestore(_ plan: DocumentPlan) throws -> RestoredSession {
        try store.save(plan)
        return RestoredSession(try store.load(plan.id))
    }

    private func texts(_ session: RestoredSession) throws -> [String] {
        let document = try PlanAssembler.assemble(session.plan, contents: session.contents).document
        return (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func mergedPlan() throws -> (DocumentPlan, a: URL, b: URL) {
        let a = try corpus.pdf(named: "A", pages: 2)
        let b = try corpus.pdf(named: "B", pages: 2)
        var plan = try DocumentPlan(source: SourceLoader.load(a).source)
        try plan.insertPages(of: SourceLoader.load(b).source, at: 1)   // A1, B1, B2, A2
        return (plan, a, b)
    }

    func testRestoreAfterCrash() throws {
        var (plan, _, _) = try mergedPlan()
        try plan.move([plan.pages[3].id], to: 0)                       // A2, A1, B1, B2
        let session = try crashAndRestore(plan)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(try texts(session), ["A page 2", "A page 1", "B page 1", "B page 2"])

        // Auch Undo funktioniert nach dem Wiederherstellen.
        var restoredPlan = session.plan
        try restoredPlan.undo()
        XCTAssertEqual(restoredPlan.pages.map(\.index), [0, 0, 1, 1])
    }

    func testMovedSourceIsFound() throws {
        let (plan, a, _) = try mergedPlan()
        let folder = corpus.url("Moved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: folder.appendingPathComponent("A renamed.pdf"))

        let session = try crashAndRestore(plan)
        XCTAssertTrue(session.isComplete, "\(session.problems)")
        XCTAssertEqual(try texts(session).first, "A page 1")
        XCTAssertEqual(session.plan.sources[0].displayName, "A.pdf")
    }

    func testMissingSourceIsReportedAndCanBeResolved() throws {
        let (plan, _, b) = try mergedPlan()
        let parked = corpus.url("parked.pdf")
        try FileManager.default.moveItem(at: b, to: parked)
        try FileManager.default.removeItem(at: parked)                 // gelöscht: Bookmark findet nichts mehr

        var session = try crashAndRestore(plan)
        XCTAssertEqual(session.problems.map(\.source.displayName), ["B.pdf"])
        guard case .missing = session.problems.first else { return XCTFail("\(session.problems)") }
        XCTAssertThrowsError(try PlanAssembler.assemble(session.plan, contents: session.contents))

        try session.removePages(from: session.problems[0].source.id)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(try texts(session), ["A page 1", "A page 2"])
    }

    func testMissingSourceCanBePutBack() throws {
        let (plan, _, b) = try mergedPlan()
        let bytes = try Data(contentsOf: b)
        try FileManager.default.removeItem(at: b)

        var session = try crashAndRestore(plan)
        XCTAssertEqual(session.problems.count, 1)
        try bytes.write(to: b)                                          // Datei zurückgelegt
        session.retry()
        XCTAssertTrue(session.isComplete, "\(session.problems)")
        XCTAssertEqual(try texts(session).count, 4)
    }

    func testChangedSourceIsReported() throws {
        let (plan, a, _) = try mergedPlan()
        try FileManager.default.removeItem(at: a)
        try corpus.pdf(named: "A", pages: 5)                            // anderer Inhalt am selben Ort

        let session = try crashAndRestore(plan)
        guard case let .changed(source)? = session.problems.first else { return XCTFail("\(session.problems)") }
        XCTAssertEqual(source.displayName, "A.pdf")
        XCTAssertTrue(session.problems[0].message.contains("A.pdf"))
    }

    /// Fehlt eine Quelle, deren Seiten alle entfernt wurden, wird nichts gemeldet.
    func testMissingSourceWithoutPagesIsNotReported() throws {
        var (plan, _, b) = try mergedPlan()
        try plan.remove(plan.pageIDs(from: plan.sources[1].id))
        try FileManager.default.removeItem(at: b)
        let session = try crashAndRestore(plan)
        XCTAssertTrue(session.isComplete, "\(session.problems)")
        XCTAssertEqual(try texts(session), ["A page 1", "A page 2"])
    }

    func testPasswordIsAskedAgain() throws {
        let url = try corpus.encryptedPDF(password: "test-password")
        let plan = try DocumentPlan(source: SourceLoader.load(url, password: "test-password").source)

        var session = try crashAndRestore(plan)
        guard case .needsPassword? = session.problems.first else { return XCTFail("\(session.problems)") }
        let id = session.plan.sources[0].id
        XCTAssertThrowsError(try session.providePassword("wrong", for: id)) {
            XCTAssertEqual($0 as? SourceLoadError, .wrongPassword(fileName: "Encrypted.pdf"))
        }
        XCTAssertFalse(session.isComplete)

        try session.providePassword("test-password", for: id)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.plan.sources[0].password, "test-password")
        XCTAssertEqual(ProtectionSuggestion(for: session.plan)?.password, "test-password")
        XCTAssertEqual(try texts(session), ["Encrypted page 1", "Encrypted page 2"])
    }

    /// Ein nachträglich gesetztes Passwort gilt auch für die Kopie der Quelle im Undo-Verlauf.
    func testPasswordReachesHistory() throws {
        let a = try SourceLoader.load(corpus.pdf(named: "A", pages: 1)).source
        let encrypted = try SourceLoader.load(corpus.encryptedPDF(password: "pw"), password: "pw").source
        var plan = try DocumentPlan(source: a)
        try plan.insertPages(of: encrypted, at: 1)
        var restored = try JSONDecoder().decode(DocumentPlan.self, from: JSONEncoder().encode(plan))
        try restored.setPassword("pw", for: encrypted.id)
        try restored.undo()
        try restored.redo()
        XCTAssertEqual(restored.source(withID: encrypted.id)?.password, "pw")
        XCTAssertThrowsError(try restored.setPassword("x", for: UUID()))
    }
}
