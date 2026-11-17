import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import PDFToMeCore

final class SourceLoaderTests: XCTestCase {
    private var corpus: TestCorpus!

    override func setUpWithError() throws {
        corpus = try TestCorpus()
    }

    override func tearDown() {
        corpus.remove()
        Localization.current = .de
        super.tearDown()
    }

    private func assertLoadFails(
        _ url: URL, password: String? = nil, with expected: SourceLoadError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try SourceLoader.load(url, password: password), file: file, line: line) {
            XCTAssertEqual($0 as? SourceLoadError, expected, file: file, line: line)
        }
    }

    // MARK: PDFs

    func testLoadPDF() throws {
        let url = try corpus.pdf(named: "Contract", pages: 3)
        let loaded = try SourceLoader.load(url)

        XCTAssertEqual(loaded.source.kind, .pdf)
        XCTAssertEqual(loaded.source.displayName, "Contract.pdf")
        XCTAssertEqual(loaded.source.pageCount, 3)
        XCTAssertNil(loaded.source.password)
        let expectedHash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(loaded.source.sha256, expectedHash)
        XCTAssertEqual(loaded.source.sha256.count, 64)

        guard case let .pdf(document) = loaded.content else { return XCTFail("expected PDF content") }
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(document.page(at: 2)?.string?.contains("Contract page 3") == true)
        XCTAssertNoThrow(try DocumentPlan(source: loaded.source))
    }

    /// Die Art wird am Inhalt erkannt: Eine PDF mit falscher Endung ist trotzdem eine PDF.
    func testDetectsPDFByContent() throws {
        let pdf = try corpus.pdf(named: "Report", pages: 1)
        let renamed = corpus.url("Report.txt")
        try FileManager.default.moveItem(at: pdf, to: renamed)
        XCTAssertEqual(try SourceLoader.load(renamed).source.kind, .pdf)
    }

    func testEncryptedPDF() throws {
        let url = try corpus.encryptedPDF(password: "test-password")
        assertLoadFails(url, with: .passwordRequired(fileName: "Encrypted.pdf"))
        assertLoadFails(url, password: "", with: .passwordRequired(fileName: "Encrypted.pdf"))
        assertLoadFails(url, password: "wrong", with: .wrongPassword(fileName: "Encrypted.pdf"))

        let loaded = try SourceLoader.load(url, password: "test-password")
        XCTAssertEqual(loaded.source.password, "test-password")
        XCTAssertEqual(loaded.source.pageCount, 2)
        guard case let .pdf(document) = loaded.content else { return XCTFail("expected PDF content") }
        XCTAssertFalse(document.isLocked)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Encrypted page 1") == true)
    }

    /// Ein Passwort für eine unverschlüsselte PDF wird ignoriert und nicht gemerkt.
    func testPasswordForUnencryptedPDFIsNotKept() throws {
        let loaded = try SourceLoader.load(corpus.pdf(named: "Plain", pages: 1), password: "unused")
        XCTAssertNil(loaded.source.password)
    }

    func testDamagedFiles() throws {
        assertLoadFails(try corpus.truncatedPDF(), with: .damagedPDF(fileName: "Truncated.pdf"))
        assertLoadFails(try corpus.notAPDF(), with: .notAPDF(fileName: "NotAPDF.pdf"))
        assertLoadFails(try corpus.emptyFile(), with: .emptyFile(fileName: "Empty.pdf"))
        assertLoadFails(corpus.url("Missing.pdf"), with: .missing(fileName: "Missing.pdf"))

        let text = corpus.url("Notes.txt")
        try Data("plain text".utf8).write(to: text)
        assertLoadFails(text, with: .unsupportedFileType(fileName: "Notes.txt"))
        assertLoadFails(corpus.directory, with: .unsupportedFileType(fileName: corpus.directory.lastPathComponent))
    }

    // MARK: Bilder

    func testLoadImages() throws {
        for format in TestCorpus.ImageFormat.allCases {
            let url = try corpus.image(named: "Photo", format: format, size: CGSize(width: 300, height: 200))
            let loaded = try SourceLoader.load(url)
            XCTAssertEqual(loaded.source.kind, .image, "\(format)")
            XCTAssertEqual(loaded.source.pageCount, 1)
            XCTAssertEqual(loaded.source.displayName, url.lastPathComponent)
            guard case let .image(image, orientation) = loaded.content else { return XCTFail("\(format)") }
            XCTAssertEqual(image.width, 300)
            XCTAssertEqual(image.height, 200)
            XCTAssertEqual(orientation, .up)
        }
    }

    func testImageOrientationIsRead() throws {
        let url = corpus.url("Rotated.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try TestCorpus.makeImage(size: CGSize(width: 40, height: 20)),
            [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        guard case let .image(_, orientation) = try SourceLoader.load(url).content else { return XCTFail() }
        XCTAssertEqual(orientation, .right)
    }

    func testRejectsOtherImageFormats() throws {
        let url = corpus.url("Scan.tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try TestCorpus.makeImage(size: CGSize(width: 10, height: 10)), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        assertLoadFails(url, with: .unsupportedFileType(fileName: "Scan.tiff"))
    }

    func testDamagedImage() throws {
        let png = try Data(contentsOf: corpus.image(named: "Photo", format: .png))
        let url = corpus.url("Broken.png")
        try png.prefix(40).write(to: url)
        XCTAssertThrowsError(try SourceLoader.load(url)) {
            // Ein abgeschnittenes PNG wird je nach ImageIO-Version als beschädigt oder als unbekannt erkannt.
            let error = $0 as? SourceLoadError
            XCTAssertTrue(error == .damagedImage(fileName: "Broken.png")
                || error == .unsupportedFileType(fileName: "Broken.png"), "\(String(describing: error))")
        }
    }

    // MARK: Wiederfinden

    func testReopenAfterRenameKeepsIdentity() throws {
        let url = try corpus.pdf(named: "Contract", pages: 2)
        let original = try SourceLoader.load(url).source
        let renamed = corpus.url("Renamed.pdf")
        try FileManager.default.moveItem(at: url, to: renamed)

        XCTAssertEqual(SourceLoader.resolve(original)?.resolvingSymlinksInPath(), renamed.resolvingSymlinksInPath())
        let resolved = try XCTUnwrap(SourceLoader.resolve(original))
        XCTAssertEqual(SourceLoader.availability(of: original), .available(resolved))

        let reopened = try SourceLoader.reopen(original)
        XCTAssertEqual(reopened.source.id, original.id)
        XCTAssertEqual(reopened.source.displayName, "Contract.pdf")
        XCTAssertEqual(reopened.source.sha256, original.sha256)
        XCTAssertEqual(reopened.source.bookmark, original.bookmark)
    }

    func testChangedSourceIsDetected() throws {
        let url = try corpus.pdf(named: "Contract", pages: 2)
        let original = try SourceLoader.load(url).source
        try corpus.pdf(named: "Contract", pages: 3)   // überschreibt die Datei mit anderem Inhalt

        guard case .changed = SourceLoader.availability(of: original) else {
            return XCTFail("expected .changed, got \(SourceLoader.availability(of: original))")
        }
        XCTAssertThrowsError(try SourceLoader.reopen(original)) {
            XCTAssertEqual($0 as? SourceLoadError, .changedSinceOpened(fileName: "Contract.pdf"))
        }
    }

    func testMissingSourceIsDetected() throws {
        let url = try corpus.pdf(named: "Contract", pages: 2)
        let original = try SourceLoader.load(url).source
        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(SourceLoader.availability(of: original), .missing)
        XCTAssertNil(SourceLoader.resolve(original))
        XCTAssertThrowsError(try SourceLoader.reopen(original)) {
            XCTAssertEqual($0 as? SourceLoadError, .missing(fileName: "Contract.pdf"))
        }
    }

    func testReopenEncryptedSource() throws {
        let url = try corpus.encryptedPDF(password: "test-password")
        let loaded = try SourceLoader.load(url, password: "test-password").source

        // Im Speicher ist das Passwort noch da und wird wiederverwendet.
        XCTAssertNoThrow(try SourceLoader.reopen(loaded))

        // Nach dem Laden einer Sitzung fehlt es; dann muss die App erneut fragen.
        let restored = try JSONDecoder().decode(SourceFile.self, from: JSONEncoder().encode(loaded))
        XCTAssertThrowsError(try SourceLoader.reopen(restored)) {
            XCTAssertTrue(($0 as? SourceLoadError)?.needsPassword == true)
        }
        XCTAssertEqual(try SourceLoader.reopen(restored, password: "test-password").source.password, "test-password")
    }

    /// Das Original bleibt beim Öffnen bytegleich.
    func testLoadingDoesNotChangeTheFile() throws {
        let url = try corpus.encryptedPDF(password: "test-password")
        let before = try Data(contentsOf: url)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = try SourceLoader.load(url, password: "test-password")
        _ = SourceLoader.availability(of: try SourceLoader.load(url, password: "test-password").source)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, attributesBefore)
    }

    // MARK: Meldungen

    func testMessagesNameFileAndCause() {
        Localization.current = .de
        XCTAssertEqual(SourceLoadError.wrongPassword(fileName: "A.pdf").errorDescription,
                       "Das Passwort für „A.pdf“ ist falsch.")
        Localization.current = .en
        XCTAssertEqual(SourceLoadError.notAPDF(fileName: "A.pdf").errorDescription,
                       "“A.pdf” is not a PDF file, although its name ends in .pdf.")
        XCTAssertTrue(SourceLoadError.passwordRequired(fileName: "A.pdf").needsPassword)
        XCTAssertFalse(SourceLoadError.damagedPDF(fileName: "A.pdf").needsPassword)
    }
}
