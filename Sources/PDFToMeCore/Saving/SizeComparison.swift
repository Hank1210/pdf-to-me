import DocKit
import Foundation

/// Größe einer verkleinert gespeicherten Datei im Vergleich, für die Meldung nach „Verkleinert speichern“.
///
/// Verglichen wird mit dem Original, wenn das Dokument aus genau einer PDF mit allen ihren Seiten besteht (gedreht
/// oder umsortiert ändert die Größe kaum); das deckt sich mit dem Finder. Sonst wäre die Originalgröße irreführend,
/// und verglichen wird mit derselben Datei ohne Bildverkleinerung.
public struct SizeComparison: Equatable, Sendable {
    public enum Reference: Equatable, Sendable {
        /// Die Originaldatei, wie der Finder sie zeigt.
        case original
        /// Dieselbe Datei, nur ohne Bildverkleinerung gespeichert.
        case unreduced
    }

    public let before: Int64
    public let after: Int64
    public let reference: Reference

    /// Unter dieser Ersparnis heißt es ehrlich, die Datei ließ sich kaum verkleinern.
    static let noticeableSaving = 0.05

    public init(before: Int64, after: Int64, reference: Reference) {
        self.before = before
        self.after = after
        self.reference = reference
    }

    /// Größe der Originaldatei, wenn sie der richtige Vergleich ist: Das Dokument besteht aus genau einer PDF und
    /// enthält jede ihrer Seiten genau einmal. Sonst `nil`.
    public static func originalSize(of plan: DocumentPlan) -> Int64? {
        let used = plan.sourcesInUse
        guard used.count == 1, let source = used.first, source.kind == .pdf,
              plan.pages.count == source.pageCount,
              Set(plan.pages.map(\.index)) == Set(0..<source.pageCount),
              let url = SourceLoader.resolve(source),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return Int64(size)
    }

    /// Ersparnis in Prozent, gerundet; 0, wenn die Datei nicht kleiner wurde.
    public var savedPercent: Int {
        guard before > 0, after < before else { return 0 }
        return Int((Double(before - after) / Double(before) * 100).rounded())
    }

    public var isNoticeable: Bool {
        before > 0 && Double(before - after) >= Double(before) * Self.noticeableSaving
    }

    /// Satz für die Meldung nach dem Speichern, z. B. „18,6 MB → 13,9 MB (−25 %).“ oder, ohne Vergleich mit dem
    /// Original, „Ohne Bildverkleinerung 15,9 MB, jetzt 13,9 MB (−13 %).“
    public var message: String {
        let from = Self.format(before), to = Self.format(after)
        switch (reference, isNoticeable) {
        case (.original, true):
            return "\(from) → \(to) (−\(savedPercent) %)."
        case (.original, false):
            return loc("Die Datei ließ sich kaum verkleinern: \(from) → \(to).",
                       "The file could hardly be reduced: \(from) → \(to).")
        case (.unreduced, true):
            return loc("Ohne Bildverkleinerung \(from), jetzt \(to) (−\(savedPercent) %).",
                       "Without reducing images \(from), now \(to) (−\(savedPercent) %).")
        case (.unreduced, false):
            return loc("Die Datei ließ sich kaum verkleinern: ohne Bildverkleinerung \(from), jetzt \(to).",
                       "The file could hardly be reduced: without reducing images \(from), now \(to).")
        }
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
