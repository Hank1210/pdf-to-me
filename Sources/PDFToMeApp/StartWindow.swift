import AppKit
import DocKit
import PDFToMeCore
import SwiftUI
import UniformTypeIdentifiers

/// Das Startfenster: erscheint, wenn kein Dokument offen ist, statt des Öffnen-Dialogs.
/// Bietet eine Ablagefläche für PDFs, „Datei öffnen …“ und die zuletzt benutzten Dateien.
/// Die Liste stammt aus `NSDocumentController.recentDocumentURLs`, also derselben Quelle wie das Menü
/// „Zuletzt benutzt“; das Fenster speichert selbst nichts.
@MainActor
final class StartWindow: NSObject, NSWindowDelegate {
    static let shared = StartWindow()

    /// Höchstzahl der zuletzt benutzten Dateien im Fenster.
    private static let recentLimit = 5

    private let model = StartModel()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// Beim Beenden schließen sich Fenster; dann soll das Startfenster nicht mehr erscheinen.
    private var isTerminating = false

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { StartWindow.shared.isTerminating = true } }
        // Schließt das letzte Dokumentfenster, erscheint wieder das Startfenster.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            let isDocumentWindow = (notification.object as? NSWindow)?.windowController?.document != nil
            guard isDocumentWindow else { return }
            // Erst nach dem Schließen ist das Dokument aus der Liste des Controllers entfernt.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { StartWindow.shared.showIfNoDocuments() }
            }
        }
    }

    func show() {
        model.message = nil
        model.recent = Array(NSDocumentController.shared.recentDocumentURLs.prefix(Self.recentLimit))
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func showIfNoDocuments() {
        guard NSDocumentController.shared.documents.isEmpty, !isTerminating else { return }
        show()
    }

    /// Wird aufgerufen, sobald ein Dokumentfenster erscheint.
    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = StartView(model: model, open: { [weak self] in self?.open($0) }, choose: {
            // Das Startfenster bleibt stehen, falls der Dialog abgebrochen wird.
            NSDocumentController.shared.openDocument(nil)
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = AppIdentity.name
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.delegate = self
        return window
    }

    /// Öffnet die übergebenen Dateien. Nur PDFs werden angenommen; Bilder werden in einem geöffneten Dokument
    /// eingefügt, nicht als eigenes Dokument geöffnet.
    private func open(_ urls: [URL]) {
        let pdfs = urls.filter(Self.isPDF)
        if pdfs.count < urls.count {
            model.message = loc(
                "Hier lassen sich nur PDFs öffnen. Bilder fügen Sie in einem geöffneten Dokument mit „Einfügen …“ hinzu.",
                "Only PDFs can be opened here. Add images to an open document with “Insert…”.")
        }
        for url in pdfs {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] document, _, error in
                MainActor.assumeIsolated {
                    if document != nil { self?.close() }
                    // Abbruch der Passwortabfrage ist kein Fehler, der gemeldet werden muss.
                    if let error, !Self.isCancellation(error) { NSApp.presentError(error) }
                }
            }
        }
    }

    private static func isPDF(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .pdf) == true
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}

@MainActor
@Observable
final class StartModel {
    var recent: [URL] = []
    /// Hinweis unter der Ablagefläche, z. B. wenn ein Bild abgelegt wurde.
    var message: String?
}

private struct StartView: View {
    let model: StartModel
    let open: ([URL]) -> Void
    let choose: () -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text(AppIdentity.name)
                    .font(.title.weight(.semibold))
                Text("Read. Annotate. Organize.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            dropArea

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            recentList
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(width: 440, height: 520)
    }

    private var dropArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(loc("PDF hierher ziehen", "Drop a PDF here"))
                .font(.headline)
            Button(loc("Datei öffnen …", "Open File…"), action: choose)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
        .dropDestination(for: URL.self) { urls, _ in
            open(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder private var recentList: some View {
        if !model.recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("Zuletzt benutzt", "Recent"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(model.recent, id: \.self) { url in
                    RecentRow(url: url) { open([url]) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.path)
    }
}
