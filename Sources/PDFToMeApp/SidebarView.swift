import PDFKit
import PDFToMeCore
import SwiftUI

/// Seitenleiste: Miniaturen, Inhaltsverzeichnis oder Suchtreffer.
struct SidebarView: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.sidebarMode) {
                Image(systemName: "square.grid.2x2")
                    .help(loc("Miniaturen", "Thumbnails"))
                    .tag(DocumentViewModel.SidebarMode.thumbnails)
                Image(systemName: "list.bullet.indent")
                    .help(loc("Inhaltsverzeichnis", "Table of Contents"))
                    .tag(DocumentViewModel.SidebarMode.outline)
                if !model.searchQuery.isEmpty {
                    Image(systemName: "magnifyingglass")
                        .help(loc("Suchtreffer", "Search Results"))
                        .tag(DocumentViewModel.SidebarMode.search)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch model.sidebarMode {
            case .thumbnails: ThumbnailList(model: model)
            case .outline: OutlineList(model: model)
            case .search: SearchResultsList(model: model)
            }
        }
        .frame(minWidth: 160)
    }
}

// MARK: - Miniaturen

private struct ThumbnailList: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selectedPages) {
                ForEach(Array(model.pageIDs.enumerated()), id: \.element) { index, id in
                    ThumbnailRow(model: model, index: index, isCurrent: index == model.currentPageIndex)
                        .tag(id)
                        .id(id)
                }
            }
            .onChange(of: model.selectedPages) { model.thumbnailSelectionDidChange() }
            .onChange(of: model.currentPageIndex) { _, index in
                guard model.pageIDs.indices.contains(index) else { return }
                proxy.scrollTo(model.pageIDs[index])
            }
        }
    }
}

private struct ThumbnailRow: View {
    let model: DocumentViewModel
    let index: Int
    let isCurrent: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(0.707, contentMode: .fit)
                }
            }
            .frame(maxWidth: 120, maxHeight: 160)
            .shadow(radius: 1)
            Text("\(index + 1)")
                .font(.caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(loc("Seite \(index + 1)", "Page \(index + 1)"))
        // Erst zeichnen, wenn die Zeile sichtbar wird; neu bei jeder neuen Vorschau.
        .task(id: TaskKey(index: index, version: model.previewVersion)) {
            image = model.page(at: index)?.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
        }
    }

    private struct TaskKey: Equatable {
        let index: Int
        let version: Int
    }
}

// MARK: - Inhaltsverzeichnis

private struct OutlineList: View {
    let model: DocumentViewModel
    @State private var selection: OutlineEntry.ID?

    var body: some View {
        if model.outline.isEmpty {
            ContentUnavailableView(
                loc("Kein Inhaltsverzeichnis", "No Table of Contents"),
                systemImage: "list.bullet.indent",
                description: Text(loc("Dieses Dokument hat kein Inhaltsverzeichnis.",
                                      "This document has no table of contents.")))
        } else {
            List(model.outline, children: \.children, selection: $selection) { entry in
                HStack {
                    Text(entry.title).lineLimit(2)
                    Spacer()
                    if let page = entry.pageIndex {
                        Text("\(page + 1)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .tag(entry.id)
            }
            .onChange(of: selection) { _, id in
                guard let id, let entry = find(id, in: model.outline), let page = entry.pageIndex else { return }
                model.go(toPage: page)
            }
        }
    }

    private func find(_ id: Int, in entries: [OutlineEntry]) -> OutlineEntry? {
        for entry in entries {
            if entry.id == id { return entry }
            if let found = find(id, in: entry.children ?? []) { return found }
        }
        return nil
    }
}

// MARK: - Suchtreffer

private struct SearchResultsList: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if model.searchResults.isEmpty {
            ContentUnavailableView.search(text: model.searchQuery)
        } else {
            VStack(spacing: 0) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                List(selection: $model.selectedMatch) {
                    ForEach(model.searchResults) { page in
                        Section(loc("Seite \(page.pageIndex + 1)", "Page \(page.pageIndex + 1)")) {
                            ForEach(page.matches) { match in
                                Text(match.snippet).lineLimit(2).font(.callout).tag(match.id)
                            }
                        }
                    }
                }
                .onChange(of: model.selectedMatch) { _, id in
                    if let id { model.show(matchID: id) }
                }
            }
        }
    }

    private var summary: String {
        let matches = model.matchCount
        let pages = model.searchResults.count
        let limited = matches >= DocumentSearch.maximumMatches
        let more = limited ? loc(" (gekürzt)", " (truncated)") : ""
        return loc("\(matches) Treffer auf \(pages) \(pages == 1 ? "Seite" : "Seiten")\(more)",
                   "\(matches) \(matches == 1 ? "match" : "matches") on \(pages) \(pages == 1 ? "page" : "pages")"
                   + more)
    }
}
