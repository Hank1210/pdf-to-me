import AppKit
import PDFKit
import PDFToMeCore
import SwiftUI

/// Das Dokumentfenster: Seitenleiste (SwiftUI) und `PDFView`, dazu Werkzeugleiste und Menüaktionen.
final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate,
    NSMenuItemValidation, DocumentActions, PDFViewZoom {
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
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, ItemID.zoomOut, ItemID.zoomIn,
         ItemID.twoPages, .space, ItemID.search]
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
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
