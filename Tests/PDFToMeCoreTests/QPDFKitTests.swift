import QPDFKit
import XCTest

/// Rauchtest: qpdf ist gebaut, gelinkt und in der erwarteten Version eingebunden (Scripts/fetch-qpdf.sh).
final class QPDFKitTests: XCTestCase {
    func testLinkedVersion() {
        XCTAssertEqual(String(cString: qpdfkit_version()), "12.4.2")
    }
}
