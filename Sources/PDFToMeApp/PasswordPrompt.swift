import AppKit
import PDFToMeCore

/// Fragt nach dem Passwort einer geschützten PDF. Das Passwort bleibt nur im Speicher (README).
enum PasswordPrompt {
    /// `nil`, wenn der Nutzer abbricht.
    static func ask(fileName: String, wrongBefore: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = wrongBefore
            ? loc("Das Passwort ist falsch.", "The password is wrong.")
            : loc("„\(fileName)“ ist mit einem Passwort geschützt.", "“\(fileName)” is protected by a password.")
        alert.informativeText = loc(
            "Geben Sie das Passwort ein, um „\(fileName)“ zu öffnen. Es wird nicht gespeichert.",
            "Enter the password to open “\(fileName)”. It is not stored.")
        alert.addButton(withTitle: loc("Öffnen", "Open"))
        alert.addButton(withTitle: loc("Abbrechen", "Cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = loc("Passwort", "Password")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
