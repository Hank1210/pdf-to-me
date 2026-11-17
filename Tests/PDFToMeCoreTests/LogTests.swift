import XCTest
@testable import PDFToMeCore

final class LogTests: XCTestCase {
    private var corpus: TestCorpus!
    private var file: URL!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
        file = corpus.url("Logs/pdf-to-me.log")
    }

    override func tearDown() {
        Log.shared.configure(file: nil)
        corpus.remove()
        super.tearDown()
    }

    private func lines(_ url: URL? = nil) throws -> [String] {
        try String(contentsOf: url ?? file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testLineFormat() throws {
        let log = Log(file: file)
        let id = UUID()
        log.info("saved", ["pages": .int(3), "protected": .bool(true), "plan": .id(id), "writer": .name("pdfkit")])
        log.warning("slow", ["seconds": .double(1.23456)])
        log.error("failed")

        let written = try lines()
        XCTAssertEqual(written.count, 3)
        XCTAssertTrue(written[0].hasSuffix(" INFO saved pages=3 protected=true plan=\(id.uuidString) writer=pdfkit"),
                      written[0])
        XCTAssertTrue(written[1].hasSuffix(" WARN slow seconds=1.235"), written[1])
        XCTAssertTrue(written[2].hasSuffix(" ERROR failed"), written[2])
        // Zeitstempel nach ISO 8601 am Anfang.
        let stamp = String(written[0].prefix { $0 != " " })
        XCTAssertNotNil(ISO8601DateFormatter().date(from: stamp.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)), stamp)

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testUnconfiguredLogWritesNothing() {
        Log(file: nil).info("nothing")
        Log.shared.info("nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRotationKeepsLimitedFiles() throws {
        let log = Log(file: file, maxBytes: 200, keptFiles: 2)
        for number in 0..<40 { log.info("entry", ["n": .int(number)]) }

        let folder = file.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["pdf-to-me.log", "pdf-to-me.log.1", "pdf-to-me.log.2"])
        for url in [file!, folder.appendingPathComponent("pdf-to-me.log.1")] {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            XCTAssertLessThanOrEqual(size, 200)
        }
        XCTAssertTrue(try lines().last?.hasSuffix("n=39") == true)
        // Der neueste Eintrag steht in der aktuellen Datei, ältere in den nummerierten.
        let previous = try lines(folder.appendingPathComponent("pdf-to-me.log.1"))
        XCTAssertLessThan(Int(previous.last!.split(separator: "=").last!)!, 39)
    }

    func testConcurrentWritesStayWholeLines() throws {
        let log = Log(file: file)
        DispatchQueue.concurrentPerform(iterations: 200) { log.info("parallel", ["n": .int($0)]) }
        let written = try lines()
        XCTAssertEqual(written.count, 200)
        XCTAssertTrue(written.allSatisfy { $0.contains(" INFO parallel n=") })
    }

    // MARK: Datenschutz

    /// Fehler erscheinen nur mit Typ und Fall, nie mit ihren Daten.
    func testErrorsAreDescribedWithoutData() {
        XCTAssertEqual(Log.describe(SourceLoadError.wrongPassword(fileName: "Secret.pdf")),
                       "SourceLoadError.wrongPassword")
        XCTAssertEqual(Log.describe(WriterError.noPages), "WriterError.noPages")
        XCTAssertEqual(Log.describe(SaveError.cannotWrite(folder: "Private", reason: "/Users/x")),
                       "SaveError.cannotWrite")
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 260,
                            userInfo: [NSFilePathErrorKey: "/Users/someone/Secret.pdf"])
        XCTAssertEqual(Log.describe(cocoa), "NSCocoaErrorDomain 260")
    }

    /// Echte Abläufe hinterlassen weder Dateinamen noch Passwörter noch Seitentext im Protokoll.
    func testRealWorkflowsLeakNothing() throws {
        Log.shared.configure(file: file)
        let secretName = "Kuendigung Erika Mustermann"
        let url = try corpus.encryptedPDF(named: secretName, password: "geheim-4711")

        XCTAssertThrowsError(try SourceLoader.load(url, password: "falsch-0815"))
        let loaded = try SourceLoader.load(url, password: "geheim-4711")
        let plan = try DocumentPlan(source: loaded.source)
        let output = corpus.url("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try SavePipeline(writer: PDFKitWriter()).save(
            plan, contents: [loaded.source.id: loaded.content], in: output, baseName: "\(secretName) (edited)",
            options: WriteOptions(password: "geheim-4711"))
        _ = RestoredSession(try JSONDecoder().decode(DocumentPlan.self, from: JSONEncoder().encode(plan)))
        XCTAssertThrowsError(try SourceLoader.load(corpus.url("\(secretName) missing.pdf")))

        let text = try String(contentsOf: file, encoding: .utf8)
        for secret in ["Kuendigung", "Mustermann", "geheim-4711", "falsch-0815", "page 1", output.path, "/Users/"] {
            XCTAssertFalse(text.contains(secret), "log contains \(secret):\n\(text)")
        }
        // Es wurde aber tatsächlich protokolliert.
        for entry in ["source not opened error=SourceLoadError.wrongPassword", "source opened", "saved",
                      "session restored", "source problem", "SourceLoadError.missing"] {
            XCTAssertTrue(text.contains(entry), "missing \(entry):\n\(text)")
        }
    }
}
