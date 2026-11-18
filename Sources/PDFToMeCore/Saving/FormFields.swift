import CoreGraphics
import Foundation

/// Liest das Formularverzeichnis `/AcroForm /Fields` einer PDF.
///
/// Nur Felder, die dort stehen, sind in einem PDF-Programm ausfüllbar. Sichtbare Widgets allein reichen nicht; das
/// zeigt PDFKit nicht an, deshalb wird hier direkt im Katalog gelesen.
enum FormFields {
    /// Namen aller Felder im Formularverzeichnis: je Feld der Teilname (`/T`) und der volle Name
    /// (`Eltern.Kind`). Leer, wenn es kein Formularverzeichnis gibt.
    static func names(in document: CGPDFDocument) -> Set<String> {
        guard let catalog = document.catalog else { return [] }
        var form: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form else { return [] }
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { return [] }
        var names = Set<String>()
        collect(fields, prefix: nil, into: &names, depth: 0)
        return names
    }

    /// Wie `names(in:)`, für eine Datei; entsperrt sie bei Bedarf mit `password`.
    static func names(at url: URL, password: String?) -> Set<String> {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        if document.isEncrypted, !document.isUnlocked {
            guard let password, document.unlockWithPassword(password) else { return [] }
        }
        return names(in: document)
    }

    private static func collect(_ array: CGPDFArrayRef, prefix: String?, into names: inout Set<String>, depth: Int) {
        // Schutz gegen zirkuläre Verweise in beschädigten Dateien.
        guard depth < 32 else { return }
        for index in 0..<CGPDFArrayGetCount(array) {
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, index, &field), let field else { continue }
            var partial: String?
            var title: CGPDFStringRef?
            if CGPDFDictionaryGetString(field, "T", &title), let title,
               let text = CGPDFStringCopyTextString(title) as String? {
                partial = text
            }
            let full = [prefix, partial].compactMap { $0 }.joined(separator: ".")
            if let partial { names.insert(partial) }
            if !full.isEmpty { names.insert(full) }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(field, "Kids", &kids), let kids {
                collect(kids, prefix: full.isEmpty ? prefix : full, into: &names, depth: depth + 1)
            }
        }
    }
}
