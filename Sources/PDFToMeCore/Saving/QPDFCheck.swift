import Foundation
import QPDFKit

/// Prüft eine geschriebene Datei mit qpdf, unabhängig von PDFKit: alle Objekte lesen, alle Datenströme dekodieren.
enum QPDFCheck {
    struct Result {
        let pageCount: Int
        let warnings: Int
    }

    /// Seitenzahl und Warnungen, oder der Grund, warum qpdf die Datei nicht lesen kann.
    static func run(_ url: URL, password: String?) -> Swift.Result<Result, VerificationFailure> {
        var pageCount: Int32 = 0
        var warnings: Int32 = 0
        var buffer = [CChar](repeating: 0, count: 1024)
        let status = buffer.withUnsafeMutableBufferPointer {
            qk_check(url.path, password, &pageCount, &warnings, $0.baseAddress, $0.count)
        }
        guard status == QK_OK else {
            return .failure(status == QK_WRONG_PASSWORD ? .wrongPassword : .notReadableByQPDF)
        }
        return .success(Result(pageCount: Int(pageCount), warnings: Int(warnings)))
    }
}
