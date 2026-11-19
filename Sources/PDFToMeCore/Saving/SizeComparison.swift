import DocKit
import Foundation

/// Größe einer verkleinert gespeicherten Datei im Vergleich zur selben Datei ohne Bildverkleinerung.
public struct SizeComparison: Equatable, Sendable {
    public let before: Int64
    public let after: Int64

    /// Unter dieser Ersparnis heißt es ehrlich, die Datei ließ sich kaum verkleinern.
    static let noticeableSaving = 0.05

    public init(before: Int64, after: Int64) {
        self.before = before
        self.after = after
    }

    /// Ersparnis in Prozent, gerundet; 0, wenn die Datei nicht kleiner wurde.
    public var savedPercent: Int {
        guard before > 0, after < before else { return 0 }
        return Int((Double(before - after) / Double(before) * 100).rounded())
    }

    public var isNoticeable: Bool {
        before > 0 && Double(before - after) >= Double(before) * Self.noticeableSaving
    }

    /// Satz für die Meldung nach dem Speichern, z. B. „12,4 MB → 2,1 MB (−83 %).“
    public var message: String {
        let from = Self.format(before), to = Self.format(after)
        guard isNoticeable else {
            return loc("Die Datei ließ sich kaum verkleinern: \(from) → \(to).",
                       "The file could hardly be reduced: \(from) → \(to).")
        }
        return "\(from) → \(to) (−\(savedPercent) %)."
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
