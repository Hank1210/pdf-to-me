import Foundation
import QPDFKit

/// Schreibt einen Plan mit qpdf (Ziel-Writer ab M1b).
///
/// Seiten werden strukturell aus den Quell-Bytes kopiert, nie neu gezeichnet. Erhalten bleiben Text, Anmerkungen,
/// interne Links (auf Seiten im Ergebnis umgeschrieben, sonst entfernt), das Inhaltsverzeichnis (aus den Quellen
/// neu aufgebaut) und Formularfelder samt Formularverzeichnis. Die neue Datei kann mit AES-256 geschützt werden.
/// Bilder werden zuerst mit `ImagePage.pdfData` zu einer einseitigen PDF. Seiten mit Texterkennung bekommen eine
/// unsichtbare Textebene, die qpdf über die unveränderte Seite legt.
public struct QPDFKitWriter: PDFWriting {
    public let capabilities: WriterCapabilities = [.pageOperations]

    /// qpdf-Instanzen werden nie geteilt; die Sperre stellt zusätzlich sicher, dass immer nur ein Schreibvorgang
    /// läuft (Speicherbedarf, einfache Fehlersuche).
    private static let lock = NSLock()

    public init() {}

    public func compose(_ plan: DocumentPlan, contents: SourceContents, to url: URL, options: WriteOptions) throws {
        let fileName = url.lastPathComponent
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriterError.destinationExists(fileName: fileName)
        }
        guard !plan.pages.isEmpty else { throw WriterError.noPages }

        try Self.lock.withLock {
            guard let composer = qk_composer_new() else { throw WriterError.writeFailed(fileName: fileName) }
            defer { qk_composer_free(composer) }

            var indices: [SourceFile.ID: Int32] = [:]
            for source in plan.sourcesInUse {
                let data: Data
                switch contents[source.id] {
                case let .pdf(_, bytes)?:
                    data = bytes
                case let .image(image, orientation)?:
                    data = try ImagePage.pdfData(image, orientation: orientation)
                case nil:
                    throw AssemblyError.missingContent(fileName: source.displayName)
                }
                let password = source.kind == .pdf ? source.password : nil
                var index: Int32 = -1
                let status = try Self.call { error, length in
                    data.withUnsafeBytes { bytes in
                        qk_add_source(composer, bytes.baseAddress, bytes.count, password, source.displayName, &index,
                                      error, length)
                    }
                }
                if status.code == QK_WRONG_PASSWORD {
                    throw SourceLoadError.passwordRequired(fileName: source.displayName)
                }
                if status.code != QK_OK {
                    throw WriterError.sourceUnreadable(fileName: source.displayName, reason: status.message)
                }
                let expectedPages = source.kind == .image ? 1 : source.pageCount
                guard qk_source_page_count(composer, index) == expectedPages else {
                    throw AssemblyError.pageMissing(fileName: source.displayName,
                                                    page: Int(qk_source_page_count(composer, index)) + 1)
                }
                indices[source.id] = index
            }

            var overlays: [TextRecognitionCache.Key: Int32] = [:]
            for (position, page) in plan.pages.enumerated() {
                guard let index = indices[page.source], let source = plan.source(of: page) else { continue }
                guard page.recognizesText else {
                    qk_add_page(composer, index, Int32(page.index), Int32(page.rotation.degrees))
                    continue
                }
                let key = TextRecognitionCache.Key(source: source, page: page)
                if overlays[key] == nil {
                    guard let recognized = options.textLayers?[key] else {
                        throw WriterError.textNotRecognized(page: position + 1)
                    }
                    guard let size = TextLayerPage.displayedSize(of: contents[source.id], pageIndex: page.index) else {
                        throw AssemblyError.pageMissing(fileName: source.displayName, page: page.index + 1)
                    }
                    let data = try TextLayerPage.pdfData(recognized, size: size)
                    var overlay: Int32 = -1
                    let status = try Self.call { error, length in
                        data.withUnsafeBytes { bytes in
                            qk_add_overlay(composer, bytes.baseAddress, bytes.count, &overlay, error, length)
                        }
                    }
                    guard status.code == QK_OK else {
                        throw WriterError.engineFailed(fileName: fileName, reason: status.message)
                    }
                    overlays[key] = overlay
                }
                qk_add_page_with_overlay(composer, index, Int32(page.index), Int32(page.rotation.degrees), overlays[key]!)
            }

            let status = try Self.call { error, length in
                qk_write(composer, url.path, options.password, AppIdentity.name, options.compact ? 1 : 0, error, length)
            }
            guard status.code == QK_OK else {
                try? FileManager.default.removeItem(at: url)
                throw WriterError.engineFailed(fileName: fileName, reason: status.message)
            }
        }
    }

    /// Ruft eine C-Funktion mit Fehlerpuffer auf.
    private static func call(_ body: (UnsafeMutablePointer<CChar>, Int) -> QKStatus) throws
        -> (code: QKStatus, message: String) {
        var buffer = [CChar](repeating: 0, count: 1024)
        let code = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count) }
        return (code, String(cString: buffer))
    }
}
