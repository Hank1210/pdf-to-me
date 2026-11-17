import Foundation

/// Drehung einer Seite im Uhrzeigersinn, wie bei `PDFPage.rotation`. Nur Vielfache von 90° sind möglich.
public enum Rotation: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case quarter = 90
    case half = 180
    case threeQuarters = 270

    public var degrees: Int { rawValue }

    /// Beliebige Gradzahl, die ein Vielfaches von 90 ist (auch negativ oder über 360). Sonst `nil`.
    public init?(degrees: Int) {
        guard degrees % 90 == 0 else { return nil }
        self.init(rawValue: ((degrees % 360) + 360) % 360)
    }

    /// Diese Drehung, ergänzt um eine weitere.
    public func rotated(by other: Rotation) -> Rotation {
        // Summe zweier Werte aus 0…270 ist immer ein Vielfaches von 90.
        Rotation(degrees: degrees + other.degrees)!
    }

    /// Die Drehung, die diese wieder aufhebt.
    public var inverse: Rotation {
        Rotation(degrees: -degrees)!
    }
}

/// Eine Seite im Ergebnis: ein Verweis auf eine Seite einer Quelle und die seitenbezogenen Änderungen.
public struct PageRef: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var source: SourceFile.ID
    /// Seitenindex in der Quelle, ab 0. Bei Bildquellen immer 0.
    public var index: Int
    /// Zusätzliche Drehung gegenüber der Seite in der Quelle.
    public var rotation: Rotation

    public init(id: UUID = UUID(), source: SourceFile.ID, index: Int, rotation: Rotation = .none) {
        self.id = id
        self.source = source
        self.index = index
        self.rotation = rotation
    }
}
