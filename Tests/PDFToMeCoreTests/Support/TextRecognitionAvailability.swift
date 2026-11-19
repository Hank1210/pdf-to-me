import DocKit
import Foundation
import XCTest

/// Auf den virtuellen Macs von GitHub Actions scheitert die Texterkennung von Vision sofort („nilError“, keine
/// Neural Engine). Dort werden Tests, die sie brauchen, übersprungen, nachdem eine Probe das bestätigt hat.
/// Lokal laufen sie immer und schlagen fehl, wenn die Texterkennung nicht geht. Wie in DocKit und Scan to me.
func requireTextRecognition() throws {
    guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
    try XCTSkipUnless(TextRecognitionProbe.works, "Die Texterkennung von Vision ist auf diesem Runner nicht verfügbar.")
}

private enum TextRecognitionProbe {
    static let works: Bool = {
        guard let image = try? TestCorpus.textImage(lines: ["Probe"], size: CGSize(width: 620, height: 877)) else {
            return false
        }
        return (try? TextRecognizer.recognize(image)) != nil
    }()
}
