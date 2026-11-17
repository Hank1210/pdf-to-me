import Foundation

/// Ein Wert im Protokoll. Bewusst nur Zahlen, Ja/Nein, Kennungen, feste Namen und Fehler: Dokumentinhalt, Dateinamen
/// und Passwörter lassen sich so gar nicht erst protokollieren (README, „Privacy and security“).
public enum LogValue {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case id(UUID)
    /// Ein fester Name aus dem Code, z. B. der Name eines Writers.
    case name(StaticString)
    /// Nur Typ und Fall des Fehlers, nie seine Daten (die enthalten oft Dateinamen).
    case error(Error)

    var text: String {
        switch self {
        case let .int(value): String(value)
        case let .double(value): String(format: "%.3f", value)
        case let .bool(value): value ? "true" : "false"
        case let .id(value): value.uuidString
        case let .name(value): "\(value)"
        case let .error(error): Log.describe(error)
        }
    }
}

/// Protokoll der App in `~/Library/Logs/PDF-to-me/pdf-to-me.log`, mit Rotation.
///
/// Meldungen und Feldnamen sind `StaticString`, also feste Texte im Code. Werte sind `LogValue`. Damit erzwingt schon
/// der Compiler, dass weder Dokumentinhalt noch Dateinamen noch Passwörter ins Protokoll gelangen.
///
/// Eigener Logger, keine Kopie von `ScanLog` aus Scan to me; in M0 wird geprüft, ob beide in DocKit zusammengehen.
public final class Log: @unchecked Sendable {
    public enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    /// Der Logger der App. Schreibt nichts, bis die App `configure(file:)` aufruft; Tests berühren so nie das
    /// echte Protokoll.
    public static let shared = Log(file: nil)

    public static let defaultMaxBytes = 1_000_000
    public static let defaultKeptFiles = 3

    private let lock = NSLock()
    private var file: URL?
    private let maxBytes: Int
    private let keptFiles: Int

    public init(file: URL?, maxBytes: Int = defaultMaxBytes, keptFiles: Int = defaultKeptFiles) {
        self.file = file
        self.maxBytes = maxBytes
        self.keptFiles = keptFiles
    }

    /// Legt die Protokolldatei fest (beim Start der App: `AppIdentity.logFile()`).
    public func configure(file: URL?) {
        lock.withLock { self.file = file }
    }

    public func info(_ message: StaticString, _ fields: KeyValuePairs<StaticString, LogValue> = [:]) {
        write(.info, message, fields)
    }

    public func warning(_ message: StaticString, _ fields: KeyValuePairs<StaticString, LogValue> = [:]) {
        write(.warning, message, fields)
    }

    public func error(_ message: StaticString, _ fields: KeyValuePairs<StaticString, LogValue> = [:]) {
        write(.error, message, fields)
    }

    // MARK: Schreiben

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func write(_ level: Level, _ message: StaticString, _ fields: KeyValuePairs<StaticString, LogValue>) {
        let parts = fields.map { "\($0.key)=\($0.value.text)" }
        let line = ([Self.timestamp.string(from: Date()), level.rawValue, "\(message)"] + parts)
            .joined(separator: " ") + "\n"
        lock.withLock {
            guard let file else { return }
            // Ein Protokoll darf die App nie zum Absturz bringen; Fehler beim Schreiben werden ignoriert.
            try? append(Data(line.utf8), to: file)
        }
    }

    private func append(_ data: Data, to file: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > 0, size + data.count > maxBytes {
            rotate(file)
        }
        if !fileManager.fileExists(atPath: file.path) {
            fileManager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// `pdf-to-me.log` → `pdf-to-me.log.1` → … → `pdf-to-me.log.<keptFiles>`; die älteste fällt weg.
    private func rotate(_ file: URL) {
        let fileManager = FileManager.default
        func numbered(_ number: Int) -> URL {
            file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).\(number)")
        }
        try? fileManager.removeItem(at: numbered(keptFiles))
        if keptFiles > 1 {
            for number in stride(from: keptFiles - 1, through: 1, by: -1) {
                try? fileManager.moveItem(at: numbered(number), to: numbered(number + 1))
            }
        }
        if keptFiles > 0 {
            try? fileManager.moveItem(at: file, to: numbered(1))
        } else {
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: Fehler beschreiben

    /// Typ und Fall eines Fehlers, ohne seine Daten: `SourceLoadError.wrongPassword`, `NSCocoaErrorDomain 260`.
    static func describe(_ error: Error) -> String {
        let mirror = Mirror(reflecting: error)
        let type = String(describing: Swift.type(of: error))
        if mirror.displayStyle == .enum {
            // Fälle mit Daten haben genau ein Kind, dessen Name der Fall ist; Fälle ohne Daten beschreiben sich selbst.
            if let label = mirror.children.first?.label { return "\(type).\(label)" }
            return "\(type).\(String(describing: error))"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
