import DocKit
import PDFToMeCore
import SwiftUI

/// Dialog „Teilen“: nach Seitenbereichen oder alle N Seiten, mit Vorschau der Dateinamen.
/// Die Teile bestimmt der Core (`Splitter`); hier wird nur eingegeben und angezeigt.
struct SplitSheet: View {
    enum Mode: Hashable { case ranges, everyN }

    let pageCount: Int
    let stem: String
    let onSplit: ([SplitPart]) -> Void
    let onCancel: () -> Void

    @State private var mode: Mode = .ranges
    @State private var ranges = ""
    @State private var pagesPerPart = 1

    private var parts: Result<[SplitPart], Error> {
        Result {
            switch mode {
            case .ranges: try Splitter.parts(fromRanges: ranges, pageCount: pageCount)
            case .everyN: try Splitter.parts(every: pagesPerPart, pageCount: pageCount)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("Dokument aufteilen", "Split Document")).font(.headline)
            Text(loc("Jeder Teil wird als eigene Datei neben dem Original gespeichert. Die Seitenzahlen beziehen "
                     + "sich auf die aktuelle Reihenfolge (\(pageCount) Seiten).",
                     "Each part is saved as a separate file next to the original. Page numbers refer to the current "
                     + "order (\(pageCount) pages)."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $mode) {
                Text(loc("Nach Seitenbereichen", "By page ranges")).tag(Mode.ranges)
                Text(loc("Alle N Seiten", "Every N pages")).tag(Mode.everyN)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch mode {
            case .ranges:
                TextField(loc("z. B. 1–3, 4–9", "e.g. 1–3, 4–9"), text: $ranges)
                    .textFieldStyle(.roundedBorder)
            case .everyN:
                Stepper(value: $pagesPerPart, in: 1...max(pageCount, 1)) {
                    Text(loc("Je \(pagesPerPart) \(pagesPerPart == 1 ? "Seite" : "Seiten") pro Datei",
                             "\(pagesPerPart) \(pagesPerPart == 1 ? "page" : "pages") per file"))
                }
            }

            preview
                .frame(minHeight: 120, maxHeight: 200)

            HStack {
                Spacer()
                Button(loc("Abbrechen", "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(loc("Aufteilen", "Split")) {
                    if case let .success(parts) = parts { onSplit(parts) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? parts.get())?.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder private var preview: some View {
        switch parts {
        case let .success(parts):
            List(parts, id: \.self) { part in
                Text(FileNaming.candidate(baseName: "\(stem) (\(part.label))", number: 1))
            }
            .listStyle(.bordered)
        case let .failure(error):
            Text(mode == .ranges && ranges.trimmingCharacters(in: .whitespaces).isEmpty
                 ? loc("Geben Sie Seitenbereiche ein, getrennt durch Komma.",
                       "Enter page ranges, separated by commas.")
                 : error.localizedDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
