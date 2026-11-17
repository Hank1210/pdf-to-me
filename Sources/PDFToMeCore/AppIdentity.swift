import Foundation

/// Feste Kennungen der App.
///
/// Ab der ersten veröffentlichten Version (V1) dürfen sie sich nicht mehr ändern, sonst verlieren bestehende
/// Installationen ihre Einstellungen, ihre Arbeitsstände und ihren Schlüsselbund-Eintrag.
public enum AppIdentity {
    public static let name = "PDF to me"
    public static let claim = "Read. Annotate. Organize."
    public static let bundleIdentifier = "io.github.pdftome.app"
    public static let keychainService = "io.github.pdftome.app"

    /// `~/Library/Application Support/PDF to me/`
    public static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// `~/Library/Logs/PDF-to-me/pdf-to-me.log`
    public static func logFile(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("PDF-to-me", isDirectory: true)
            .appendingPathComponent("pdf-to-me.log", isDirectory: false)
    }
}
