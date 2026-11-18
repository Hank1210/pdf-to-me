import QPDFKit
@testable import PDFToMeCore
import XCTest

/// Rauchtest: qpdf ist gebaut, gelinkt und in der erwarteten Version eingebunden (Scripts/fetch-qpdf.sh).
final class QPDFKitTests: XCTestCase {
    func testLinkedVersion() {
        XCTAssertEqual(String(cString: qpdfkit_version()), "12.4.2")
    }
}

final class QPDFCheckTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        super.tearDown()
    }

    func testGoodFile() throws {
        guard case let .success(result) = QPDFCheck.run(try corpus.linkedPDF(), password: nil) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.warnings, 0)
    }

    func testProtectedFile() throws {
        let url = try corpus.encryptedPDF(password: "pw")
        guard case .success = QPDFCheck.run(url, password: "pw") else { return XCTFail("expected success") }
        guard case .failure(.wrongPassword) = QPDFCheck.run(url, password: "wrong") else {
            return XCTFail("expected wrong password")
        }
    }

    func testGarbageFails() throws {
        guard case .failure(.notReadableByQPDF) = QPDFCheck.run(try corpus.notAPDF(), password: nil) else {
            return XCTFail("expected failure")
        }
    }

    /// Ein beschädigter Datenstrom: qpdf repariert nachsichtig und meldet eine Warnung (die ins Protokoll geht).
    func testDamagedStreamGivesWarning() throws {
        let garbage = "not really deflated"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>",
            "<< /Length \(garbage.utf8.count) /Filter /FlateDecode >>\nstream\n\(garbage)\nendstream",
        ]
        let url = corpus.url("Damaged stream.pdf")
        try Data(TestCorpus.pdfFile(objects: objects).utf8).write(to: url)
        guard case let .success(result) = QPDFCheck.run(url, password: nil) else { return XCTFail("expected success") }
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertGreaterThan(result.warnings, 0)
    }
}
