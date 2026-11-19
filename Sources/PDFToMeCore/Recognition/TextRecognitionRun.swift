import CoreGraphics
import DocKit
import Foundation
import PDFKit

/// Texterkennung für die vorgemerkten Seiten eines Plans.
///
/// Jede Quellseite wird so gerastert, wie sie angezeigt wird (sichtbarer Ausschnitt, eigene Drehung der Quelle),
/// und mit `TextRecognizer` aus DocKit erkannt. Die Kästen im Ergebnis sind normalisiert (0…1, Ursprung unten links)
/// und beziehen sich auf diese angezeigte Seite, ohne die zusätzliche Drehung aus dem Plan (`PageRef.rotation`).
/// So passt ein Ergebnis zu jeder Verwendung derselben Quellseite.
///
/// Gerastert wird aus einer eigenen Lesung der Originalbytes, nicht aus den `PDFDocument`s, die das Fenster
/// anzeigt: Die Arbeit läuft im Hintergrund, und PDFKit-Objekte sind nicht für gleichzeitigen Zugriff gedacht.
public enum TextRecognitionRun {
    /// Auflösung beim Rastern. 300 dpi ist für Vision bei normaler Schriftgröße ausreichend.
    static let dpi: CGFloat = 300
    /// Obergrenze für die längere Bildseite, damit sehr große Seiten nicht unnötig viel Speicher brauchen.
    static let maxPixels = 5000

    /// Eine zu erkennende Quellseite, unabhängig von PDFKit-Objekten des Fensters.
    public struct Job: @unchecked Sendable {
        enum Input {
            case pdf(Data, password: String?)
            case image(CGImage, orientation: CGImagePropertyOrientation)
        }

        public let key: TextRecognitionCache.Key
        /// Erste Position einer Seite mit diesem Inhalt im Plan, ab 1. Für Meldungen.
        public let pageNumber: Int
        let input: Input
        let pageIndex: Int
    }

    // MARK: Auswahl

    /// Die Seiten aus `ids`, die noch keine Textebene haben. Seiten mit Text werden übersprungen, damit kein
    /// doppelter Text entsteht; Bildseiten haben nie Text.
    public static func pagesWithoutText(
        _ ids: [PageRef.ID], plan: DocumentPlan, contents: SourceContents
    ) -> [PageRef.ID] {
        var documents: [SourceFile.ID: PDFDocument] = [:]
        return ids.filter { id in
            guard let page = plan.page(withID: id) else { return false }
            switch contents[page.source] {
            case .image:
                return true
            case let .pdf(_, data):
                guard let source = plan.source(of: page) else { return false }
                if documents[source.id] == nil { documents[source.id] = freshDocument(data, password: source.password) }
                let text = documents[source.id]?.page(at: page.index)?.string ?? ""
                return text.allSatisfy(\.isWhitespace)
            case nil:
                return false
            }
        }
    }

    /// Vorgemerkte Seiten ohne Ergebnis im Zwischenspeicher, z. B. nach einem Neustart oder vor dem Speichern.
    /// Jede Quellseite erscheint nur einmal.
    public static func pendingJobs(
        plan: DocumentPlan, contents: SourceContents, cache: TextRecognitionCache
    ) -> [Job] {
        var seen = Set<TextRecognitionCache.Key>()
        return plan.pages.enumerated().compactMap { position, page -> Job? in
            guard page.recognizesText, let source = plan.source(of: page) else { return nil }
            let key = TextRecognitionCache.Key(source: source, page: page)
            guard cache[key] == nil, seen.insert(key).inserted else { return nil }
            let input: Job.Input
            switch contents[source.id] {
            case let .pdf(_, data): input = .pdf(data, password: source.password)
            case let .image(image, orientation): input = .image(image, orientation: orientation)
            case nil: return nil
            }
            return Job(key: key, pageNumber: position + 1, input: input, pageIndex: page.index)
        }
    }

    // MARK: Erkennen

    /// Erkennt die Seiten nacheinander und legt jedes Ergebnis sofort im Zwischenspeicher ab. Bei Abbruch
    /// (`CancellationError`) oder Fehler bleiben die schon erkannten Seiten erhalten.
    /// `progress(fertig, gesamt)` kommt nach jeder Seite.
    public static func run(
        _ jobs: [Job], cache: TextRecognitionCache, timeout: TimeInterval = TextRecognizer.pageTimeout,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws {
        guard !jobs.isEmpty else { return }
        let start = Date()
        // Je Quelle eine Lesung; Schlüssel ist die Prüfsumme der Quelle.
        var documents: [String: PDFDocument] = [:]
        for (number, job) in jobs.enumerated() {
            try Task.checkCancellation()
            do {
                let result: RecognizedPage
                switch job.input {
                case let .pdf(data, password):
                    let sha = job.key.sha256
                    if documents[sha] == nil { documents[sha] = freshDocument(data, password: password) }
                    guard let page = documents[sha]?.page(at: job.pageIndex), let image = render(page) else {
                        throw TextRecognitionError.pageFailed(page: job.pageNumber, reason: nil)
                    }
                    result = try await recognize(image, timeout: timeout)
                case let .image(image, orientation):
                    result = try await recognizeImagePage(image, orientation: orientation, timeout: timeout)
                }
                cache[job.key] = result
            } catch let error as TextRecognitionError {
                throw error
            } catch {
                Log.shared.error("text recognition failed", ["error": .error(error)])
                throw TextRecognitionError.pageFailed(
                    page: job.pageNumber, reason: (error as? LocalizedError)?.errorDescription)
            }
            await progress(number + 1, jobs.count)
        }
        Log.shared.info("text recognized", ["pages": .int(jobs.count), "seconds": .double(Date().timeIntervalSince(start))])
    }

    // MARK: Rastern

    /// Die Seite so, wie sie angezeigt wird: sichtbarer Ausschnitt (CropBox) und eigene Drehung der Quelle.
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(dpi / 72, CGFloat(maxPixels) / max(size.width, size.height))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // `draw(with:to:)` berücksichtigt Ausschnitt und Drehung der Seite und zeichnet in 0…Seitengröße.
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    // MARK: Hilfen

    private static func recognize(_ image: CGImage, timeout: TimeInterval) async throws -> RecognizedPage {
        try await runWithTimeout(seconds: timeout, timeoutError: TextRecognizerError.timedOut) {
            try TextRecognizer.recognize(image)
        }
    }

    /// Ein Bild wird zur A4-Seite (`ImagePage`); die Kästen werden vom Bild auf diese Seite umgerechnet.
    private static func recognizeImagePage(
        _ image: CGImage, orientation: CGImagePropertyOrientation, timeout: TimeInterval
    ) async throws -> RecognizedPage {
        let upright = try ImagePage.uprightImage(image, orientation: orientation)
        let imageSize = CGSize(width: upright.width, height: upright.height)
        let pageSize = ImagePage.pageSize(forImageOf: imageSize)
        let fitted = ImagePage.fittedRect(imageSize: imageSize, in: CGRect(origin: .zero, size: pageSize))
        let recognized = try await recognize(upright, timeout: timeout)
        return RecognizedPage(lines: recognized.lines.map { line in
            RecognizedLine(text: line.text, box: CGRect(
                x: (fitted.minX + line.box.minX * fitted.width) / pageSize.width,
                y: (fitted.minY + line.box.minY * fitted.height) / pageSize.height,
                width: line.box.width * fitted.width / pageSize.width,
                height: line.box.height * fitted.height / pageSize.height))
        })
    }

    static func freshDocument(_ data: Data, password: String?) -> PDFDocument? {
        guard let document = PDFDocument(data: data) else { return nil }
        if document.isLocked, let password { _ = document.unlock(withPassword: password) }
        return document.isLocked ? nil : document
    }
}

/// Die Texterkennung einer Seite ist fehlgeschlagen.
public enum TextRecognitionError: Error, Equatable, LocalizedError {
    /// `page` ist die Seitennummer im Dokument (ab 1), `reason` die Ursache, falls bekannt.
    case pageFailed(page: Int, reason: String?)

    public var errorDescription: String? {
        switch self {
        case let .pageFailed(page, reason):
            let message = loc("Der Text auf Seite \(page) konnte nicht erkannt werden.",
                              "The text on page \(page) could not be recognized.")
            return reason.map { message + " " + $0 } ?? message
        }
    }
}
