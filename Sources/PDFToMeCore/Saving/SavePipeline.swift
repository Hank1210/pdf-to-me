import Darwin
import Foundation

/// Ergebnis eines erfolgreichen Speicherns.
public struct SaveResult: Equatable, Sendable {
    /// Wo die neue Datei liegt.
    public let url: URL
    public let warnings: [SaveWarning]
}

/// Speichert einen Plan als neue, geprüfte Datei. Das Original wird nie verändert, nichts wird überschrieben.
///
/// ```text
/// compose()  →  temporäre Datei auf demselben Volume wie das Ziel
///     ↓
/// prüfen (SaveVerifier); bei Fehler bleibt die temporäre Datei für die Diagnose liegen, außer sie enthält
/// ungeschützt Seiten aus einer passwortgeschützten Quelle
///     ↓
/// freien Namen wählen ("Name.pdf", "Name 2.pdf" …) und atomar ohne Überschreiben dorthin verschieben
/// ```
public struct SavePipeline {
    public let writer: any PDFWriting

    public init(writer: any PDFWriting) {
        self.writer = writer
    }

    /// Speichert `plan` im Ordner `directory` unter `baseName` (ohne Endung), bei Kollision nummeriert.
    public func save(
        _ plan: DocumentPlan, contents: SourceContents, in directory: URL, baseName: String,
        options: WriteOptions = WriteOptions()
    ) throws -> SaveResult {
        let started = Date()
        let expected = try PlanAssembler.assemble(plan, contents: contents)
        let temporary = try Self.temporaryURL(near: directory)
        do {
            try writer.compose(plan, contents: contents, to: temporary, options: options)
        } catch {
            try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
            Log.shared.error("write failed", ["plan": .id(plan.id), "error": .error(error)])
            throw error
        }

        let failures = SaveVerifier.failures(
            of: temporary, expected: expected, plan: plan, password: options.password)
        guard failures.isEmpty else {
            for failure in failures {
                Log.shared.error("save check failed", ["plan": .id(plan.id), "failure": .name(failure.logName)])
            }
            // Eine ungeschützte Kopie aus einer geschützten Quelle bleibt nicht liegen, auch nicht zur Diagnose.
            if options.password == nil, ProtectionSuggestion(for: plan) != nil {
                try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
                throw SaveError.verificationFailed(failures, diagnosticFile: nil)
            }
            throw SaveError.verificationFailed(failures, diagnosticFile: temporary)
        }
        let warnings = SaveVerifier.warnings(of: temporary, plan: plan)

        let destination = try Self.moveWithoutOverwriting(temporary, to: directory, baseName: baseName)
        try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
        Log.shared.info("saved", [
            "plan": .id(plan.id), "pages": .int(plan.pages.count), "warnings": .int(warnings.count),
            "protected": .bool(options.password != nil), "seconds": .double(Date().timeIntervalSince(started)),
        ])
        return SaveResult(url: destination, warnings: warnings)
    }

    // MARK: Intern

    /// Eine Datei in einem eigenen temporären Ordner auf demselben Volume wie `directory`, damit das Verschieben
    /// atomar ist.
    static func temporaryURL(near directory: URL) throws -> URL {
        let folder: URL
        do {
            folder = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        } catch {
            throw SaveError.cannotWrite(folder: directory.lastPathComponent, reason: error.localizedDescription)
        }
        return folder.appendingPathComponent("\(UUID().uuidString).pdf", isDirectory: false)
    }

    /// Verschiebt atomar an den ersten freien Namen. `RENAME_EXCL` lässt das Umbenennen fehlschlagen, statt eine
    /// Datei zu überschreiben, die zwischen Namenswahl und Umbenennen entstanden ist.
    static func moveWithoutOverwriting(_ file: URL, to directory: URL, baseName: String) throws -> URL {
        for number in 1...10_000 {
            let candidate = directory.appendingPathComponent(
                FileNaming.candidate(baseName: baseName, number: number), isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) { continue }
            if renamex_np(file.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            if code == EEXIST { continue }
            throw SaveError.cannotWrite(
                folder: directory.lastPathComponent, reason: String(cString: strerror(code)))
        }
        throw SaveError.noFreeName(baseName: baseName)
    }
}

/// Warum nicht gespeichert wurde. Das Original ist in jedem Fall unverändert.
public enum SaveError: Error, Equatable, LocalizedError {
    /// Die Prüfung ist fehlgeschlagen. Die geschriebene Datei bleibt zur Diagnose an `diagnosticFile` liegen;
    /// `nil`, wenn sie gelöscht wurde, weil sie ungeschützt Inhalte einer geschützten Quelle enthielt.
    case verificationFailed([VerificationFailure], diagnosticFile: URL?)
    case cannotWrite(folder: String, reason: String)
    case noFreeName(baseName: String)

    public var errorDescription: String? {
        switch self {
        case let .verificationFailed(failures, _):
            let reasons = failures.map(\.message).joined(separator: " ")
            return loc("Die Datei wurde nicht gespeichert, weil die Prüfung fehlgeschlagen ist. \(reasons) "
                       + "Ihr Original ist unverändert.",
                       "The file was not saved because the check failed. \(reasons) Your original is unchanged.")
        case let .cannotWrite(folder, reason):
            return loc("Im Ordner „\(folder)“ lässt sich nicht speichern: \(reason)",
                       "Cannot save in the folder “\(folder)”: \(reason)")
        case let .noFreeName(baseName):
            return loc("Für „\(baseName)“ ist kein freier Dateiname mehr zu finden.",
                       "No free file name could be found for “\(baseName)”.")
        }
    }
}
