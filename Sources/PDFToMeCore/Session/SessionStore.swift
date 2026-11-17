import Foundation

/// Sichert Arbeitsstände, damit ungespeicherte Arbeit einen Absturz übersteht.
///
/// Jeder Plan liegt als `Sessions/<id>.json` in `Application Support/PDF to me/`. Gesichert werden nur Verweise auf
/// die Quellen und die Liste der Änderungen, nie Dokumentinhalt und nie Passwörter (README, „Privacy and
/// security“). Die Dateien sind nur für den eigenen Benutzer lesbar.
public struct SessionStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Der Standardordner `~/Library/Application Support/PDF to me/Sessions/`.
    public static func standard() throws -> SessionStore {
        SessionStore(directory: try AppIdentity.applicationSupportDirectory()
            .appendingPathComponent("Sessions", isDirectory: true))
    }

    public func url(for id: DocumentPlan.ID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// Sichert den Plan atomar; ein Absturz während des Schreibens hinterlässt die vorige Fassung.
    public func save(_ plan: DocumentPlan) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(plan)
        let url = url(for: plan.id)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Entfernt die Sicherung, z. B. nachdem der Nutzer das Fenster ohne Speichern geschlossen hat.
    public func remove(_ id: DocumentPlan.ID) throws {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func load(_ id: DocumentPlan.ID) throws -> DocumentPlan {
        try JSONDecoder().decode(DocumentPlan.self, from: Data(contentsOf: url(for: id)))
    }

    /// Alle gesicherten Arbeitsstände, die neuesten zuerst. Beschädigte Dateien werden nicht still übergangen,
    /// sondern in `damaged` gemeldet; die App entscheidet, ob sie gelöscht werden.
    public func loadAll() throws -> (sessions: [DocumentPlan], damaged: [URL]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { modificationDate($0) > modificationDate($1) }

        var sessions: [DocumentPlan] = []
        var damaged: [URL] = []
        for file in files {
            if let plan = try? JSONDecoder().decode(DocumentPlan.self, from: Data(contentsOf: file)) {
                sessions.append(plan)
            } else {
                damaged.append(file)
            }
        }
        return (sessions, damaged)
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
