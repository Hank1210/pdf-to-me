import AppKit
import DocKit
import PDFKit
import PDFToMeCore
import SwiftUI

/// Das Dokumentfenster: Seitenleiste (SwiftUI) und `PDFView`, dazu Werkzeugleiste und Menüaktionen.
final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate,
    NSMenuItemValidation, NSToolbarItemValidation, DocumentActions, PDFViewZoom, PageCommands {
    private let model: DocumentViewModel
    private let pdfView = PDFView()
    private let splitViewController = NSSplitViewController()
    private var searchItem: NSSearchToolbarItem?
    private var pageObserver: NSObjectProtocol?

    init(document: PDFToMeDocument, working: WorkingDocument) {
        model = DocumentViewModel(working: working)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)

        configurePDFView()
        configureSplitView()
        window.contentViewController = splitViewController
        window.setContentSize(NSSize(width: 1000, height: 760))
        window.setFrameAutosaveName("DocumentWindow")
        configureToolbar()
        window.initialFirstResponder = pdfView

        working.onChange = { [weak self] in self?.model.previewDidChange() }
        model.pdfView = pdfView
        model.commands = self
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        // Fenster zu: eine laufende Erkennung nicht weiterrechnen lassen.
        recognitionTask?.cancel()
    }

    // MARK: Aufbau

    private func configurePDFView() {
        pdfView.document = model.document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let page = self.pdfView.currentPage else { return }
                self.model.pageDidChange(to: self.model.document.index(for: page))
            }
        }
    }

    private func configureSplitView() {
        let sidebar = NSHostingController(rootView: SidebarView(model: model))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true

        let content = NSViewController()
        content.view = pdfView
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.autosaveName = "DocumentSplitView"
    }

    // MARK: Werkzeugleiste

    private enum ItemID {
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
        static let twoPages = NSToolbarItem.Identifier("twoPages")
        static let search = NSToolbarItem.Identifier("search")
        static let rotateLeft = NSToolbarItem.Identifier("rotateLeft")
        static let rotateRight = NSToolbarItem.Identifier("rotateRight")
        static let insert = NSToolbarItem.Identifier("insert")
        static let split = NSToolbarItem.Identifier("split")
        static let recognize = NSToolbarItem.Identifier("recognize")
        static let save = NSToolbarItem.Identifier("save")
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "DocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ItemID.rotateLeft, ItemID.rotateRight, ItemID.insert,
         ItemID.split, ItemID.recognize, .flexibleSpace, ItemID.zoomOut, ItemID.zoomIn, ItemID.twoPages, .space, ItemID.save,
         ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ItemID.zoomOut:
            return button(identifier, loc("Verkleinern", "Zoom Out"), "minus.magnifyingglass",
                          #selector(zoomOut(_:)))
        case ItemID.zoomIn:
            return button(identifier, loc("Vergrößern", "Zoom In"), "plus.magnifyingglass", #selector(zoomIn(_:)))
        case ItemID.twoPages:
            return button(identifier, loc("Zwei Seiten", "Two Pages"), "rectangle.split.2x1",
                          #selector(toggleTwoPages(_:)))
        case ItemID.rotateLeft:
            return button(identifier, loc("Nach links drehen", "Rotate Left"), "rotate.left",
                          #selector(rotateLeft(_:)))
        case ItemID.rotateRight:
            return button(identifier, loc("Nach rechts drehen", "Rotate Right"), "rotate.right",
                          #selector(rotateRight(_:)))
        case ItemID.insert:
            return button(identifier, loc("Dateien einfügen", "Insert Files"), "doc.badge.plus",
                          #selector(insertFiles(_:)))
        case ItemID.split:
            return button(identifier, loc("Aufteilen", "Split"), "scissors", #selector(splitDocument(_:)))
        case ItemID.recognize:
            return button(identifier, loc("Text erkennen", "Recognize Text"), "text.viewfinder",
                          #selector(recognizeTextInDocument(_:)))
        case ItemID.save:
            return button(identifier, loc("Als Kopie speichern", "Save as Copy"), "square.and.arrow.down",
                          #selector(saveCopy(_:)))
        case ItemID.search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = loc("Suchen", "Search")
            item.searchField.placeholderString = loc("Im Dokument suchen", "Search in document")
            item.searchField.delegate = self
            item.searchField.sendsWholeSearchString = true
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
                        _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ItemID.zoomIn: return pdfView.canZoomIn
        case ItemID.zoomOut: return pdfView.canZoomOut
        case ItemID.rotateLeft, ItemID.rotateRight, ItemID.split, ItemID.save: return !model.pageIDs.isEmpty
        case ItemID.recognize: return !model.pageIDs.isEmpty && recognitionTask == nil
        default: return true
        }
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        model.search(sender.stringValue)
    }

    // MARK: Menüaktionen

    func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    func showThumbnails(_ sender: Any?) { showSidebar(.thumbnails) }
    func showOutline(_ sender: Any?) { showSidebar(.outline) }

    private func showSidebar(_ mode: DocumentViewModel.SidebarMode) {
        model.sidebarMode = mode
        if let sidebar = splitViewController.splitViewItems.first, sidebar.isCollapsed {
            sidebar.animator().isCollapsed = false
        }
    }

    func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }

    func resetZoom(_ sender: Any?) {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }

    func zoomToFit(_ sender: Any?) {
        pdfView.autoScales = true
    }

    func toggleTwoPages(_ sender: Any?) {
        pdfView.displayMode = pdfView.displayMode == .twoUpContinuous ? .singlePageContinuous : .twoUpContinuous
    }

    func goToPreviousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    func goToNextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    func goToFirstPage(_ sender: Any?) { pdfView.goToFirstPage(sender) }
    func goToLastPage(_ sender: Any?) { pdfView.goToLastPage(sender) }

    // MARK: Seiten-Werkstatt

    private var pdfDocument: PDFToMeDocument? { document as? PDFToMeDocument }

    func rotateLeft(_ sender: Any?) { rotatePages(model.targetPageIDs, by: .threeQuarters) }
    func rotateRight(_ sender: Any?) { rotatePages(model.targetPageIDs, by: .quarter) }

    /// Entf in der Seitenleiste oder „Bearbeiten → Löschen“.
    @objc func delete(_ sender: Any?) { deletePages(model.targetPageIDs) }

    func extractSelectedPages(_ sender: Any?) { extractPages(model.targetPageIDs) }
    func printSelectedPages(_ sender: Any?) { printPages(model.targetPageIDs) }

    /// Druckt nur die gewählten Seiten in Dokumentreihenfolge (README: „selected pages“).
    func printPages(_ ids: [PageRef.ID]) {
        guard let window, let pdfDocument, let working = pdfDocument.working, !ids.isEmpty else { return }
        do {
            let selection = try working.plan.extracting(ids)
            let document = try PlanAssembler.assemble(selection, contents: working.contents).document
            guard let operation = document.printOperation(
                for: pdfDocument.printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
            else { return }
            operation.jobTitle = working.displayName
            operation.printPanel.options.formUnion([.showsCopies, .showsPreview, .showsOrientation, .showsScaling,
                                                    .showsPaperSize])
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } catch {
            pdfDocument.presentErrorSheet(error)
        }
    }

    func insertFiles(_ sender: Any?) {
        guard let urls = FileImport.chooseFiles() else { return }
        insertFiles(urls, at: model.insertPosition)
    }

    func saveCopy(_ sender: Any?) {
        guard let pdfDocument, let window else { return }
        afterRecognition { SaveFlow.saveCopy(of: pdfDocument, window: window) }
    }

    func splitDocument(_ sender: Any?) {
        afterRecognition { [weak self] in self?.showSplitSheet() }
    }

    private func showSplitSheet() {
        guard let window, let working = pdfDocument?.working else { return }
        var sheet: NSViewController?
        let view = SplitSheet(
            pageCount: working.plan.pages.count, stem: working.stem,
            onSplit: { parts in
                if let sheet { window.contentViewController?.dismiss(sheet) }
                SaveFlow.split(working, into: parts, window: window)
            },
            onCancel: { if let sheet { window.contentViewController?.dismiss(sheet) } })
        let controller = NSHostingController(rootView: view)
        sheet = controller
        window.contentViewController?.presentAsSheet(controller)
    }

    func movePages(_ ids: [PageRef.ID], to position: Int) {
        pdfDocument?.perform(loc("Seiten verschieben", "Move Pages")) {
            try $0.change { try $0.move(ids, to: position) }
        }
    }

    func insertFiles(_ urls: [URL], at position: Int) {
        let loaded = FileImport.load(urls, window: window)
        guard !loaded.isEmpty else { return }
        let before = model.pageIDs.count
        pdfDocument?.perform(loc("Dateien einfügen", "Insert Files")) { try $0.insertFiles(loaded, at: position) }
        // Die neuen Seiten auswählen, damit man sieht, wo sie gelandet sind.
        let inserted = model.pageIDs.count - before
        if inserted > 0, position + inserted <= model.pageIDs.count {
            model.selectedPages = Set(model.pageIDs[position..<(position + inserted)])
        }
    }

    func rotatePages(_ ids: [PageRef.ID], by rotation: Rotation) {
        guard !ids.isEmpty else { return }
        pdfDocument?.perform(loc("Drehen", "Rotate")) { try $0.change { try $0.rotate(ids, by: rotation) } }
    }

    func deletePages(_ ids: [PageRef.ID]) {
        guard !ids.isEmpty else { return }
        pdfDocument?.perform(loc("Seiten löschen", "Delete Pages")) { try $0.change { try $0.remove(ids) } }
    }

    func extractPages(_ ids: [PageRef.ID]) {
        guard let window, let working = pdfDocument?.working, !ids.isEmpty else { return }
        afterRecognition { SaveFlow.extract(ids, of: working, window: window) }
    }

    // MARK: Texterkennung

    /// Die laufende Erkennung; es läuft immer höchstens eine je Fenster.
    private var recognitionTask: Task<Void, Never>?

    func recognizeTextInDocument(_ sender: Any?) { recognizeText(model.pageIDs) }
    func recognizeTextOnSelectedPages(_ sender: Any?) { recognizeText(model.targetPageIDs) }

    /// Merkt Seiten ohne Text vor (ein Undo-Schritt) und erkennt sie sofort im Hintergrund.
    func recognizeText(_ ids: [PageRef.ID]) {
        guard let pdfDocument, let working = pdfDocument.working, recognitionTask == nil, !ids.isEmpty else { return }
        var marked: [PageRef.ID] = []
        pdfDocument.perform(loc("Text erkennen", "Recognize Text")) { marked = try $0.markedForTextRecognition(ids) }
        guard !marked.isEmpty || !working.pendingRecognition.isEmpty else {
            let alert = NSAlert()
            alert.messageText = ids.count == model.pageIDs.count
                ? loc("Alle Seiten haben schon Text.", "All pages already have text.")
                : loc("Die ausgewählten Seiten haben schon Text.", "The selected pages already have text.")
            alert.informativeText = loc("Texterkennung ist nur für gescannte Seiten ohne Text nötig.",
                                        "Text recognition is only needed for scanned pages without text.")
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        runRecognition(cancelling: marked, then: nil)
    }

    func cancelTextRecognition() {
        recognitionTask?.cancel()
    }

    /// Führt `action` aus, sobald alle vorgemerkten Seiten erkannt sind; erkennt fehlende vorher (z. B. nach einem
    /// Neustart). Bei Abbruch oder Fehler entfällt `action`.
    private func afterRecognition(_ action: @escaping () -> Void) {
        guard let working = pdfDocument?.working, recognitionTask == nil else {
            if recognitionTask != nil { NSSound.beep() }
            return
        }
        if working.pendingRecognition.isEmpty { action() } else { runRecognition(cancelling: [], then: action) }
    }

    /// `cancelling`: Seiten, deren Vormerkung beim Abbrechen zurückgenommen wird (die dieses Durchlaufs).
    private func runRecognition(cancelling marked: [PageRef.ID], then action: (() -> Void)?) {
        guard let pdfDocument, let working = pdfDocument.working else { return }
        let jobs = working.pendingRecognition
        guard !jobs.isEmpty else {
            action?()
            return
        }
        let cache = working.recognitionCache
        model.recognitionProgress = (0, jobs.count)
        recognitionTask = Task { [weak self] in
            var failure: Error?
            do {
                try await TextRecognitionRun.run(jobs, cache: cache) { done, total in
                    await MainActor.run { self?.model.recognitionProgress = (done, total) }
                }
            } catch {
                failure = error
            }
            guard let self else { return }
            self.recognitionTask = nil
            self.model.recognitionProgress = nil
            switch failure {
            case nil:
                action?()
            case is CancellationError:
                if !marked.isEmpty {
                    pdfDocument.perform(loc("Texterkennung abbrechen", "Cancel Text Recognition")) {
                        try $0.stopTextRecognition(marked)
                    }
                }
            case let error?:
                pdfDocument.presentErrorSheet(error)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasPages = !model.pageIDs.isEmpty
        switch menuItem.action {
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(delete(_:)),
             #selector(extractSelectedPages(_:)), #selector(printSelectedPages(_:)):
            return hasPages
        case #selector(saveCopy(_:)), #selector(splitDocument(_:)):
            return hasPages
        case #selector(recognizeTextInDocument(_:)), #selector(recognizeTextOnSelectedPages(_:)):
            return hasPages && recognitionTask == nil
        case #selector(toggleTwoPages(_:)):
            menuItem.state = pdfView.displayMode == .twoUpContinuous ? .on : .off
        case #selector(showThumbnails(_:)):
            menuItem.state = model.sidebarMode == .thumbnails ? .on : .off
        case #selector(showOutline(_:)):
            menuItem.state = model.sidebarMode == .outline ? .on : .off
        case #selector(zoomIn(_:)):
            return pdfView.canZoomIn
        case #selector(zoomOut(_:)):
            return pdfView.canZoomOut
        case #selector(goToPreviousPage(_:)), #selector(goToFirstPage(_:)):
            return pdfView.canGoToPreviousPage
        case #selector(goToNextPage(_:)), #selector(goToLastPage(_:)):
            return pdfView.canGoToNextPage
        default:
            break
        }
        return true
    }
}
