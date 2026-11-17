import XCTest
@testable import PDFToMeCore

final class AppIdentityTests: XCTestCase {
    /// Diese Werte sind ab V1 festgeschrieben. Schlägt der Test fehl, wurde eine Kennung geändert.
    func testFixedIdentifiers() {
        XCTAssertEqual(AppIdentity.name, "PDF to me")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "io.github.pdftome.app")
        XCTAssertEqual(AppIdentity.keychainService, "io.github.pdftome.app")
    }

    func testApplicationSupportDirectory() throws {
        let url = try AppIdentity.applicationSupportDirectory()
        XCTAssertEqual(url.lastPathComponent, "PDF to me")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    func testLogFile() throws {
        let url = try AppIdentity.logFile()
        XCTAssertTrue(url.path.hasSuffix("/Library/Logs/PDF-to-me/pdf-to-me.log"), url.path)
    }

    /// Info.plist und Code müssen denselben Bundle-Identifier verwenden.
    func testInfoPlistMatchesIdentity() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PDFToMeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Paket-Wurzel
        let plistURL = packageRoot.appendingPathComponent("Support/PDFToMe-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier)
        XCTAssertEqual(plist["CFBundleName"] as? String, AppIdentity.name)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "PDFToMeApp")
    }
}
