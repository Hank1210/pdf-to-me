import AppKit
import PDFToMeCore
import UniformTypeIdentifiers

/// Liest abgelegte Dateien aus Drag & Drop.
enum FileDrop {
    /// Sammelt die Datei-URLs aller Elemente und ruft `completion` einmal auf dem Hauptthread auf.
    static func urls(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.withLock { urls.append((index, url)) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ordered = urls.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { completion(ordered) }
        }
    }
}

/// Öffnet Dateien zum Einfügen: fragt bei geschützten PDFs nach dem Passwort und meldet, was nicht ging.
@MainActor
enum FileImport {
    /// Dateitypen für den Dialog „Dateien einfügen“.
    static let allowedTypes: [UTType] = [.pdf, .jpeg, .png, .heic]

    /// Die geladenen Dateien in der gegebenen Reihenfolge. Fehler werden gesammelt am Fenster gemeldet.
    static func load(_ urls: [URL], window: NSWindow?) -> [LoadedSource] {
        var loaded: [LoadedSource] = []
        var failures: [String] = []
        for url in urls {
            do {
                if let source = try load(url) { loaded.append(source) }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failures.count == 1
                ? loc("Eine Datei konnte nicht eingefügt werden.", "One file could not be inserted.")
                : loc("\(failures.count) Dateien konnten nicht eingefügt werden.",
                      "\(failures.count) files could not be inserted.")
            alert.informativeText = failures.joined(separator: "\n\n")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        return loaded
    }

    /// `nil`, wenn der Nutzer die Passwortabfrage abbricht.
    private static func load(_ url: URL) throws -> LoadedSource? {
        do {
            return try SourceLoader.load(url)
        } catch let error as SourceLoadError where error.needsPassword {
            var wrongBefore = false
            while true {
                guard let password = PasswordPrompt.ask(fileName: url.lastPathComponent, wrongBefore: wrongBefore)
                else { return nil }
                do {
                    return try SourceLoader.load(url, password: password)
                } catch let error as SourceLoadError where error.needsPassword {
                    wrongBefore = true
                }
            }
        }
    }

    /// Dialog „Dateien einfügen“. `nil` bei Abbruch.
    static func chooseFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.message = loc("Wählen Sie PDFs oder Bilder (JPEG, PNG, HEIC) zum Einfügen.",
                            "Choose PDFs or images (JPEG, PNG, HEIC) to insert.")
        panel.prompt = loc("Einfügen", "Insert")
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
