# Changelog

All notable user-facing changes to PDF to me are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and version numbers follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.0] - 2026-11-19

### Added

- Text recognition for scanned pages: Pages › Recognize Text, or the toolbar button, makes them searchable and lets
  you select their text. Recognition runs on your Mac. Only pages without text are processed, and the recognized
  text is saved as an invisible layer, so the pages look unchanged. Thumbnails mark recognized pages, and the
  recognition can be cancelled.
- File › Save Reduced (⌥⌘S) saves a copy with images reduced to 150 dpi as JPEG (quality 75 %) and reports
  the size before and after. One-bit, masked, CMYK and palette images stay unchanged, and an image is only
  replaced when it gets smaller. Text, links, form fields, bookmarks and recognized text are kept.

### Changed

- Saved files are written more compactly without losing anything: objects are packed into compressed object
  streams, streams are recompressed, and fonts or images that no page uses are left out. Text, links, form fields,
  bookmarks and images stay exactly as they were.

### Fixed

- A page that appears more than once in a document no longer takes over the rotation of its first copy when saved.

### Internal

- The language selection now comes from DocKit, the package shared with Scan to me. No change for users.

## [1.0.0] - 2026-11-18

First public version.

### Read

- Continuous scrolling, zoom and an optional two-page view.
- Search across the whole document, with matches listed by page.
- Table of contents and page thumbnails in the sidebar.
- Printing of the whole document or selected pages.
- Password-protected PDFs: the app asks for the password and never stores it.
- A start window when no document is open: drop a PDF, open a file or pick one of the five most recently used.

### Organize

- Merge PDFs and images by dragging them into the thumbnail sidebar.
- Split a document by page ranges or every N pages. Parts are saved next to the original.
- Rearrange, rotate, delete and extract pages, with undo and redo.
- Insert JPEG, PNG and HEIC images as pages.
- Outlines, internal links and form fields are kept when merging and splitting. Pages are copied with qpdf, not
  redrawn.
- New files from a password-protected source can be protected with a password (AES-256).

### Safe saving

- The original file is never changed, and no file is overwritten.
- Every new file is checked before it is saved: page count, text, links, form fields, outline and structure.
- Unsaved work is restored after a crash.

### Distribution

- Universal app for Apple silicon and Intel, macOS 14 or later.
- Community build: ad hoc signed, not notarized, published as a zip file with a SHA-256 checksum.
- German and English user interface.

[Unreleased]: https://github.com/Hank1210/pdf-to-me/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Hank1210/pdf-to-me/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Hank1210/pdf-to-me/releases/tag/v1.0.0
