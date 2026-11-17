import Foundation

/// Eine Quelldatei eines Dokuments. Sie wird nur gelesen, nie verändert.
///
/// Gespeichert werden nur Verweise (Bookmark, Prüfsumme, Name), nie der Inhalt. Das Passwort einer verschlüsselten
/// PDF liegt nur im Speicher: Es wird nicht kodiert und erscheint in keiner Textdarstellung.
public struct SourceFile: Identifiable, Hashable, Sendable {
    /// Art der Quelle. Ein Bild wird erst beim Anzeigen und Speichern zu einer Seite.
    public enum Kind: String, Codable, Sendable {
        case pdf
        case image
    }

    public let id: UUID
    public var kind: Kind
    /// Ursprünglicher Dateiname, z. B. `Vertrag.pdf`. Für Zielnamen und für Meldungen, wenn die Quelle fehlt.
    public var displayName: String
    /// Bookmark auf die Datei; überlebt Umbenennen und Verschieben innerhalb des Volumes.
    public var bookmark: Data
    /// SHA-256 des Dateiinhalts (hex, klein geschrieben). Erkennt, ob sich die Quelle extern geändert hat.
    public var sha256: String
    /// Seitenzahl beim Öffnen. Bei Bildern immer 1.
    public var pageCount: Int
    /// Nur im Speicher, nie persistiert, nie protokolliert.
    public var password: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        bookmark: Data,
        sha256: String,
        pageCount: Int,
        password: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.bookmark = bookmark
        self.sha256 = sha256
        self.pageCount = pageCount
        self.password = password
    }
}

// MARK: - Codable ohne Passwort

extension SourceFile: Codable {
    // `password` fehlt bewusst: Es darf nie in eine Sitzungsdatei gelangen.
    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, bookmark, sha256, pageCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(Kind.self, forKey: .kind),
            displayName: try container.decode(String.self, forKey: .displayName),
            bookmark: try container.decode(Data.self, forKey: .bookmark),
            sha256: try container.decode(String.self, forKey: .sha256),
            pageCount: try container.decode(Int.self, forKey: .pageCount),
            password: nil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(bookmark, forKey: .bookmark)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(pageCount, forKey: .pageCount)
    }
}

// MARK: - Textdarstellung ohne Passwort

// `print`, `dump`, String-Interpolation und der Debugger zeigen nur, ob ein Passwort gesetzt ist.
extension SourceFile: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SourceFile(id: \(id), kind: \(kind.rawValue), displayName: \(displayName), pageCount: \(pageCount), "
            + "hasPassword: \(password != nil))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "id": id,
            "kind": kind,
            "displayName": displayName,
            "sha256": sha256,
            "pageCount": pageCount,
            "hasPassword": password != nil,
        ])
    }
}
