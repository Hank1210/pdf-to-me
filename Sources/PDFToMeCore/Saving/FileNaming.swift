import DocKit
import Foundation

/// Dateinamen für gespeicherte Dateien. Nie überschreibend: Ist ein Name vergeben, wird nummeriert.
public enum FileNaming {
    /// Die Kennzeichnung bearbeiteter Dateien in beiden Sprachen; beim erneuten Bearbeiten wird sie erkannt.
    static let editedMarkers = ["bearbeitet", "edited"]

    /// Name ohne Endung für die bearbeitete Fassung, z. B. `Vertrag.pdf` → `Vertrag (bearbeitet)`.
    ///
    /// Ist die Datei schon eine bearbeitete Fassung (`Vertrag (bearbeitet).pdf` oder `Vertrag (bearbeitet) 2.pdf`),
    /// bleibt es bei einer Kennzeichnung; die Nummer ergibt sich beim Speichern.
    public static func editedBaseName(forOriginal fileName: String) -> String {
        "\(stem(of: fileName)) (\(loc("bearbeitet", "edited")))"
    }

    /// Name ohne Endung und ohne eine vorhandene Kennzeichnung als bearbeitet (samt Nummer).
    static func stem(of fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let markers = editedMarkers.joined(separator: "|")
        let pattern = "^(.+) \\((?:\(markers))\\)(?: \\d+)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
              let range = Range(match.range(at: 1), in: base)
        else { return base }
        return String(base[range])
    }

    /// Die Kandidaten in Reihenfolge: `Name.pdf`, `Name 2.pdf`, `Name 3.pdf` …
    public static func candidate(baseName: String, number: Int, pathExtension: String = "pdf") -> String {
        number <= 1 ? "\(baseName).\(pathExtension)" : "\(baseName) \(number).\(pathExtension)"
    }
}
