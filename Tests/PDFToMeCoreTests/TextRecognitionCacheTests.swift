import DocKit
import XCTest
@testable import PDFToMeCore

final class TextRecognitionCacheTests: XCTestCase {
    private func source(_ sha: Character, pages: Int = 3) -> SourceFile {
        SourceFile(kind: .pdf, displayName: "\(sha).pdf", bookmark: Data([1]),
                   sha256: String(repeating: sha, count: 64), pageCount: pages)
    }

    private func page(_ text: String) -> RecognizedPage {
        RecognizedPage(lines: [RecognizedLine(text: text, box: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05))])
    }

    func testStoreAndRead() {
        let cache = TextRecognitionCache()
        let key = TextRecognitionCache.Key(sha256: "abc", pageIndex: 2)
        XCTAssertNil(cache[key])
        cache[key] = page("Rechnung")
        XCTAssertEqual(cache[key]?.text, "Rechnung")
        XCTAssertNil(cache[TextRecognitionCache.Key(sha256: "abc", pageIndex: 1)])
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    /// Der Schlüssel hängt an Datei und Seite, nicht an der Drehung oder der Position im Dokument.
    func testKeyIgnoresRotationAndPosition() throws {
        let a = source("a")
        var plan = try DocumentPlan(source: a)
        try plan.insert([PageRef(source: a.id, index: 0)], at: 3)
        try plan.rotate([plan.pages[3].id], by: .half)
        XCTAssertEqual(TextRecognitionCache.Key(source: a, page: plan.pages[0]),
                       TextRecognitionCache.Key(source: a, page: plan.pages[3]))
    }

    /// Nach einem Neustart fehlen die Ergebnisse vorgemerkter Seiten; jede Quellseite wird nur einmal genannt.
    func testMissingKeys() throws {
        let a = source("a"), b = source("b", pages: 2)
        var plan = try DocumentPlan(source: a)
        try plan.insertPages(of: b, at: 3)
        try plan.insert([PageRef(source: a.id, index: 1)], at: 5)
        try plan.recognizeText(plan.pages.filter { $0.index == 1 }.map(\.id))
        let cache = TextRecognitionCache()
        XCTAssertEqual(cache.missingKeys(in: plan), [
            .init(sha256: a.sha256, pageIndex: 1), .init(sha256: b.sha256, pageIndex: 1),
        ])
        cache[.init(sha256: a.sha256, pageIndex: 1)] = page("erkannt")
        XCTAssertEqual(cache.missingKeys(in: plan), [.init(sha256: b.sha256, pageIndex: 1)])
    }

    func testConcurrentAccess() {
        let cache = TextRecognitionCache()
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            let key = TextRecognitionCache.Key(sha256: "s\(index % 50)", pageIndex: index % 7)
            cache[key] = page("\(index)")
            _ = cache[key]
        }
        // 50 Prüfsummen × 7 Seiten ergeben 350 verschiedene Schlüssel; keiner darf verloren gehen.
        XCTAssertEqual(cache.count, 350)
    }
}
