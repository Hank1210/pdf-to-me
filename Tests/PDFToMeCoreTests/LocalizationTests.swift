import XCTest
@testable import PDFToMeCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        Localization.current = .de
        super.tearDown()
    }

    func testSystemDefault() {
        XCTAssertEqual(AppLanguage.systemDefault(preferred: ["de-DE", "en-US"]), .de)
        XCTAssertEqual(AppLanguage.systemDefault(preferred: ["en-GB", "de-DE"]), .en)
        XCTAssertEqual(AppLanguage.systemDefault(preferred: ["fr-FR"]), .en)
        XCTAssertEqual(AppLanguage.systemDefault(preferred: []), .en)
    }

    func testLocPicksCurrentLanguage() {
        Localization.current = .de
        XCTAssertEqual(loc("Öffnen", "Open"), "Öffnen")
        Localization.current = .en
        XCTAssertEqual(loc("Öffnen", "Open"), "Open")
    }
}
