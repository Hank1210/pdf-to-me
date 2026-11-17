import PDFKit
import XCTest
@testable import PDFToMeCore

final class FileNamingTests: XCTestCase {
    override func tearDown() {
        Localization.current = .de
        super.tearDown()
    }

    func testEditedBaseName() {
        Localization.current = .de
        XCTAssertEqual(FileNaming.editedBaseName(forOriginal: "Vertrag.pdf"), "Vertrag (bearbeitet)")
        Localization.current = .en
        XCTAssertEqual(FileNaming.editedBaseName(forOriginal: "Contract.pdf"), "Contract (edited)")
    }

    /// Eine schon bearbeitete Fassung bekommt keine zweite Kennzeichnung; die Nummer entsteht beim Speichern.
    func testEditedBaseNameOfEditedFile() {
        Localization.current = .en
        for name in ["Contract (edited).pdf", "Contract (edited) 2.pdf", "Contract (bearbeitet) 12.pdf"] {
            XCTAssertEqual(FileNaming.editedBaseName(forOriginal: name), "Contract (edited)", name)
        }
        // Nur eine echte Kennzeichnung am Ende zählt.
        XCTAssertEqual(FileNaming.editedBaseName(forOriginal: "Notes (edited) draft.pdf"),
                       "Notes (edited) draft (edited)")
        XCTAssertEqual(FileNaming.editedBaseName(forOriginal: "(edited).pdf"), "(edited) (edited)")
        XCTAssertEqual(FileNaming.editedBaseName(forOriginal: "Scan 2024.pdf"), "Scan 2024 (edited)")
    }

    func testCandidates() {
        XCTAssertEqual(FileNaming.candidate(baseName: "Contract (edited)", number: 1), "Contract (edited).pdf")
        XCTAssertEqual(FileNaming.candidate(baseName: "Contract (edited)", number: 2), "Contract (edited) 2.pdf")
        XCTAssertEqual(FileNaming.candidate(baseName: "Contract (1–3)", number: 3), "Contract (1–3) 3.pdf")
    }
}

final class SavePipelineTests: XCTestCase {
    private var corpus: TestCorpus!
    private var plan: DocumentPlan!
    private var contents: SourceContents = [:]
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

    private func save(
        with writer: any PDFWriting = PDFKitWriter(), baseName: String = "Contract (edited)",
        options: WriteOptions = WriteOptions()
    ) throws -> SaveResult {
        try SavePipeline(writer: writer)
            .save(plan, contents: contents, in: output, baseName: baseName, options: options)
    }

    private func outputFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
    }

    // MARK: Erfolg

    func testSavesCheckedFileAndNeverOverwrites() throws {
        let original = try corpus.linkedPDF(named: "Contract")
        let originalBytes = try Data(contentsOf: original)
        try add(original)
        try plan.move([plan.pages[2].id], to: 0)

        let first = try save()
        XCTAssertEqual(first.url.lastPathComponent, "Contract (edited).pdf")
        XCTAssertEqual(first.warnings, [])
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: first.url)).pageCount, 3)
        let firstBytes = try Data(contentsOf: first.url)

        let second = try save()
        XCTAssertEqual(second.url.lastPathComponent, "Contract (edited) 2.pdf")
        XCTAssertEqual(try outputFiles(), ["Contract (edited) 2.pdf", "Contract (edited).pdf"])

        XCTAssertEqual(try Data(contentsOf: first.url), firstBytes)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    func testSkipsNamesThatAreTaken() throws {
        try add(corpus.pdf(named: "Contract", pages: 1))
        for name in ["Contract (edited).pdf", "Contract (edited) 2.pdf"] {
            try Data("keep me".utf8).write(to: output.appendingPathComponent(name))
        }
        XCTAssertEqual(try save().url.lastPathComponent, "Contract (edited) 3.pdf")
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Contract (edited).pdf")),
                       Data("keep me".utf8))
    }

    /// Entsteht eine Datei zwischen Namenswahl und Umbenennen, wird sie nicht überschrieben.
    func testExclusiveMoveDoesNotOverwrite() throws {
        let file = corpus.url("new.pdf")
        try Data("new".utf8).write(to: file)
        let taken = output.appendingPathComponent("Name.pdf")
        try Data("old".utf8).write(to: taken)

        let destination = try SavePipeline.moveWithoutOverwriting(file, to: output, baseName: "Name")
        XCTAssertEqual(destination.lastPathComponent, "Name 2.pdf")
        XCTAssertEqual(try Data(contentsOf: taken), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPasswordProtectedOutputIsChecked() throws {
        try add(corpus.encryptedPDF(password: "test-password"), password: "test-password")
        let result = try save(options: WriteOptions(password: "test-password"))
        let document = try XCTUnwrap(PDFDocument(url: result.url))
        XCTAssertTrue(document.isLocked)
        XCTAssertTrue(document.unlock(withPassword: "test-password"))
    }

    func testMergedFormsLinksAndImages() throws {
        try add(corpus.linkedPDF())
        try add(corpus.formPDF())
        try add(corpus.image(named: "Photo", format: .heic))
        try add(corpus.mixedScriptPDF())
        try plan.rotate([plan.pages[1].id], by: .quarter)
        XCTAssertEqual(try save().url.lastPathComponent, "Contract (edited).pdf")
    }

    // MARK: Prüfung schlägt fehl

    /// Jede Art von Fehler wird erkannt; am Ziel landet nichts, die Datei bleibt zur Diagnose liegen.
    func testVerificationFailures() throws {
        try add(corpus.linkedPDF())
        try add(corpus.formPDF())
        let cases: [(writer: BrokenWriter, expected: (VerificationFailure) -> Bool)] = [
            (.garbage, { $0 == .cannotOpen }),
            (.dropLastPage, { $0 == .pageCount(expected: 4, actual: 3) }),
            (.swapFirstTwoPages, { if case .textMismatch(page: 1) = $0 { true } else { false } }),
            (.stripLinks, { if case .linksMissing(page: 1, expected: 1, actual: 0) = $0 { true } else { false } }),
            (.stripOutline, { $0 == .outlineMissing(expected: 3, actual: 0) }),
            (.stripFormFields, { if case .formFieldsMissing(page: 4, _, _) = $0 { true } else { false } }),
            (.wrongPassword, { $0 == .wrongPassword }),
        ]
        for (writer, expected) in cases {
            XCTAssertThrowsError(try save(with: writer, options: WriteOptions(password: nil))) { error in
                guard case let .verificationFailed(failures, diagnosticFile) = error as? SaveError else {
                    return XCTFail("\(writer): \(error)")
                }
                XCTAssertTrue(failures.contains(where: expected), "\(writer): \(failures)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticFile.path), "\(writer)")
                try? FileManager.default.removeItem(at: diagnosticFile.deletingLastPathComponent())
            }
            XCTAssertEqual(try outputFiles(), [], "\(writer)")
        }
    }

    func testWriterErrorLeavesNothingBehind() throws {
        try add(corpus.pdf(named: "A", pages: 1))
        try plan.remove(plan.pages.map(\.id))
        XCTAssertThrowsError(try save()) { XCTAssertEqual($0 as? WriterError, .noPages) }
        XCTAssertEqual(try outputFiles(), [])
    }

    func testFailureMessageNamesCause() {
        Localization.current = .en
        defer { Localization.current = .de }
        let error = SaveError.verificationFailed([.pageCount(expected: 4, actual: 3)], diagnosticFile: output)
        XCTAssertEqual(error.errorDescription,
                       "The file was not saved because the check failed. The new file has 3 pages instead of 4. "
                       + "Your original is unchanged.")
    }

    // MARK: Hinweise und Stichproben

    /// Gewarnt wird, wenn die neue Datei mehr als doppelt so groß ist wie die genutzten Quellen (plus Spielraum).
    func testSizeWarning() throws {
        try add(corpus.pdf(named: "Small", pages: 1))
        let small = try corpus.pdf(named: "SameSize", pages: 1)
        let large = try corpus.pdf(named: "Large", pages: 200)
        XCTAssertEqual(SaveVerifier.warnings(of: small, plan: plan, slack: 0), [])
        XCTAssertEqual(SaveVerifier.warnings(of: large, plan: plan), [], "within the 1 MB slack")
        guard case let .unexpectedlyLarge(bytes, sourceBytes) = SaveVerifier.warnings(
            of: large, plan: plan, slack: 0).first
        else { return XCTFail("expected a size warning without slack") }
        XCTAssertGreaterThan(bytes, sourceBytes * 2)
    }

    func testTextSamplesCoverEverySource() throws {
        let a = try add(corpus.pdf(named: "A", pages: 7))
        try add(corpus.pdf(named: "B", pages: 1))
        try plan.insert([PageRef(source: a.id, index: 0)], at: 8)
        // A steht an 0…6 und 8, B an 7.
        XCTAssertEqual(SaveVerifier.textSamplePositions(plan), [0, 4, 7, 8])
    }
}

final class ProtectionSuggestionTests: XCTestCase {
    private func source(_ name: String, password: String?) -> SourceFile {
        SourceFile(kind: .pdf, displayName: name, bookmark: Data(), sha256: "", pageCount: 1, password: password)
    }

    func testNoSuggestionWithoutProtectedSource() throws {
        let plan = try DocumentPlan(source: source("A.pdf", password: nil))
        XCTAssertNil(ProtectionSuggestion(for: plan))
    }

    func testFirstProtectedSourceInPageOrderWins() throws {
        let a = source("A.pdf", password: nil)
        let b = source("B.pdf", password: "pw-b")
        let c = source("C.pdf", password: "pw-c")
        var plan = try DocumentPlan(source: a)
        try plan.insertPages(of: b, at: 1)
        try plan.insertPages(of: c, at: 1)                  // Reihenfolge A, C, B
        let suggestion = try XCTUnwrap(ProtectionSuggestion(for: plan))
        XCTAssertEqual(suggestion.password, "pw-c")
        XCTAssertEqual(suggestion.protectedSourceNames, ["C.pdf", "B.pdf"])
        XCTAssertFalse("\(suggestion)".contains("pw-"))
        XCTAssertFalse(String(reflecting: suggestion).contains("pw-"))
    }

    /// Eine geschützte Quelle ohne Seiten im Dokument zählt nicht.
    func testProtectedSourceWithoutPagesIsIgnored() throws {
        var plan = try DocumentPlan(source: source("A.pdf", password: nil))
        try plan.insertPages(of: source("B.pdf", password: "pw"), at: 1)
        try plan.remove([plan.pages[1].id])
        XCTAssertNil(ProtectionSuggestion(for: plan))
    }
}

/// Writer, die absichtlich fehlerhafte Dateien schreiben, um die Prüfung zu testen.
private enum BrokenWriter: PDFWriting, CustomStringConvertible {
    case garbage, dropLastPage, swapFirstTwoPages, stripLinks, stripOutline, stripFormFields, wrongPassword

    var capabilities: WriterCapabilities { [.pageOperations] }
    var description: String { "\(self as Any)" }

    func compose(_ plan: DocumentPlan, contents: SourceContents, to url: URL, options: WriteOptions) throws {
        if self == .garbage {
            try Data("garbage".utf8).write(to: url)
            return
        }
        // Seiten nicht nachträglich aus dem fertigen Dokument entfernen oder tauschen: PDFKit stürzt danach beim
        // Schreiben über verwaiste Formularfelder. Stattdessen einen veränderten Plan zusammensetzen.
        var changed = plan
        switch self {
        case .dropLastPage:
            try changed.remove([plan.pages[plan.pages.count - 1].id])
        case .swapFirstTwoPages:
            try changed.move([plan.pages[1].id], to: 0)
        default:
            break
        }
        let document = try PlanAssembler.assemble(changed, contents: contents).document
        switch self {
        case .stripLinks:
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                page.annotations.filter { $0.type == "Link" }.forEach(page.removeAnnotation)
            }
        case .stripOutline:
            document.outlineRoot = nil
        case .stripFormFields:
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                page.annotations.filter { $0.type == "Widget" }.forEach(page.removeAnnotation)
            }
        case .garbage, .wrongPassword, .dropLastPage, .swapFirstTwoPages:
            break
        }
        var writeOptions: [PDFDocumentWriteOption: Any] = [:]
        if self == .wrongPassword {
            writeOptions[.userPasswordOption] = "unexpected"
            writeOptions[.ownerPasswordOption] = "unexpected"
        }
        guard document.write(to: url, withOptions: writeOptions) else { throw WriterError.writeFailed(fileName: "") }
    }
}
