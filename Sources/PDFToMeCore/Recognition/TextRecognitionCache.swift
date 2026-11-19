import DocKit
import Foundation

/// Ergebnisse der Texterkennung, nur im Arbeitsspeicher.
///
/// Schlüssel ist die Seite einer Quelle (Prüfsumme der Datei und Seitenindex), nicht die `PageRef`: Dieselbe Seite
/// mehrfach im Dokument wird nur einmal erkannt, und die Drehung spielt keine Rolle, weil die Textebene im
/// Koordinatensystem der Originalseite liegt. Nichts davon wird auf die Festplatte geschrieben (README,
/// PRIVACY.md: keine Dokumentinhalte in den Daten zur Wiederherstellung).
public final class TextRecognitionCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let sha256: String
        public let pageIndex: Int

        public init(sha256: String, pageIndex: Int) {
            self.sha256 = sha256
            self.pageIndex = pageIndex
        }

        public init(source: SourceFile, page: PageRef) {
            self.init(sha256: source.sha256, pageIndex: page.index)
        }
    }

    private let lock = NSLock()
    private var results: [Key: RecognizedPage] = [:]

    public init() {}

    public subscript(key: Key) -> RecognizedPage? {
        get { lock.withLock { results[key] } }
        set { lock.withLock { results[key] = newValue } }
    }

    public var count: Int { lock.withLock { results.count } }

    /// Seiten aus dem Plan, die vorgemerkt sind, aber noch kein Ergebnis haben, z. B. nach einem Neustart.
    /// Jede Seite einer Quelle erscheint nur einmal.
    public func missingKeys(in plan: DocumentPlan) -> [Key] {
        var seen = Set<Key>()
        return plan.pages.compactMap { page -> Key? in
            guard page.recognizesText, let source = plan.source(of: page) else { return nil }
            let key = Key(source: source, page: page)
            guard self[key] == nil, seen.insert(key).inserted else { return nil }
            return key
        }
    }

    public func removeAll() {
        lock.withLock { results.removeAll() }
    }
}
