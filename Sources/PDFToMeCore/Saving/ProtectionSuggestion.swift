import Foundation

/// Vorbelegung für die Frage „Mit Passwort schützen?“ im Speichern-Dialog.
///
/// Stammen Seiten aus einer geschützten Quelle, fragt der Dialog; vorbelegt ist „Ja“ mit dem Passwort der ersten
/// geschützten Quelle in Reihenfolge der Seiten. Ohne geschützte Quelle wird nicht gefragt und ohne Passwort
/// gespeichert. (Entscheidung vom 17.11.2026, ARCHITECTURE.md Abschnitt 16.)
public struct ProtectionSuggestion: Equatable, Sendable {
    /// Vorgeschlagenes Passwort.
    public let password: String
    /// Namen der geschützten Quellen mit Seiten im Dokument, für den Hinweistext.
    public let protectedSourceNames: [String]

    /// `nil`, wenn keine Seite aus einer geschützten Quelle stammt; dann wird nicht gefragt.
    ///
    /// Eine Quelle gilt als geschützt, wenn ihr Passwort im Speicher liegt: `SourceLoader` behält es nur bei
    /// verschlüsselten PDFs, und eine wiederhergestellte Sitzung fragt es beim erneuten Öffnen wieder ab.
    public init?(for plan: DocumentPlan) {
        var seen = Set<SourceFile.ID>()
        var protected: [SourceFile] = []
        for page in plan.pages where seen.insert(page.source).inserted {
            if let source = plan.source(of: page), let password = source.password, !password.isEmpty {
                protected.append(source)
            }
        }
        guard let first = protected.first, let password = first.password else { return nil }
        self.password = password
        self.protectedSourceNames = protected.map(\.displayName)
    }
}

// Das Passwort taucht in keiner Textdarstellung auf (wie bei `SourceFile`).
extension ProtectionSuggestion: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ProtectionSuggestion(protectedSourceNames: \(protectedSourceNames))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["protectedSourceNames": protectedSourceNames]) }
}
