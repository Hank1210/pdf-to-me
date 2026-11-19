# PDF to me

<p align="center">
  <img src="https://github.com/Hank1210/pdf-to-me/releases/download/v1.0.0/PDF-to-me-icon.png" width="160" alt="PDF to me app icon">
</p>

<p align="center"><strong>Read. Annotate. Organize.</strong></p>

A native macOS app for everyday work with PDFs. Read documents, rearrange their pages, merge several files into one
or split one into several. Make scanned pages searchable and files smaller.

The app needs no account, no cloud storage and no subscription. Your documents stay on your Mac, and your original
files are never changed.

> **Status:** version 1.1.0 is available on [GitHub Releases](https://github.com/Hank1210/pdf-to-me/releases).

PDF to me is the sister app of [Scan to me](https://github.com/Hank1210/scan-to-me).

## Features

### Read

- **Start window.** When no document is open, the app shows a start window. Drop a PDF on it, open a file or
  pick one of the five most recently used.

- **Continuous scrolling** with zoom and an optional two-page view.

- **Search** across the whole document. Matches are listed by page.

- **Table of contents and thumbnails.** The sidebar shows the document's outline or a thumbnail for every page.

- **Print** the whole document or selected pages.

- **Password-protected PDFs.** The app asks for the password when you open the file. The password is never stored.

### Organize

- **Merge.** Drag PDFs or images into the thumbnail sidebar, between any two pages. A color marker shows which file
  each page comes from.

- **Split** a document by page ranges or every N pages. Each part is saved next to the original, for example
  `Contract (1–3).pdf` and `Contract (4–9).pdf`.

- **Rearrange pages.** Drag thumbnails to reorder them. Rotate, delete or extract single pages or a selection.

- **Insert images as pages.** JPEG, PNG and HEIC files become pages of their own.

- **Structure is kept.** Merging and splitting copy pages as they are. Outlines, links and form fields survive.

### Text recognition and smaller files

- **Text recognition.** Pages › Recognize Text, or the toolbar button, makes scanned pages searchable and lets you
  select and copy their text in other apps. Recognition runs on your Mac with Apple's Vision framework. Only pages
  without text are processed. When you save, the text is added as an invisible layer; the page looks the same as
  before.

- **Compact saving.** Every saved file is written compactly without losing anything. Text, links, form fields,
  bookmarks and images stay exactly as they are.

- **Save Reduced.** File › Save Reduced (⌥⌘S) also reduces images to 150 dpi and stores them as JPEG. This helps
  most with scans and photos. The app tells you the size before and after. Black-and-white scans and images that
  would not get smaller stay unchanged.

### Annotate

Highlights, notes, drawings, form filling and signatures are planned for later versions. See [Roadmap](#roadmap).

### Safe saving

- **Your original is never changed.** Saving always creates a new file, such as `Contract (edited).pdf`.

- **Nothing is overwritten.** If a name is taken, the app adds a number: `Contract (edited) 2.pdf`.

- **Every file is checked before it is saved.** The app reopens the new file and verifies the page count, the text
  and the links. If the check fails, the file is not saved and you see why.

- **Unsaved work survives a crash.** After a restart the app restores your changes. If a source file can no
  longer be found or was changed in the meantime, it tells you.

### Languages

German and English user interface.

## Roadmap

Planned after version 1, roughly in this order:

1. Highlights, notes, drawings and text boxes; filling in PDF forms; signatures as an image
2. Editing existing text and replacing images in a limited way; true redaction that removes the content; version
   history
3. Optional AI help: split suggestions, file names, questions about a document

## What PDF to me does not do

PDF to me covers everyday tasks. For these you still need a specialized tool such as Adobe Acrobat:

- digital signatures with certificates and time stamps
- XFA forms
- PDF/A conformance checks
- converting PDFs to Word or other Office formats
- editing paragraphs with text reflow

## Requirements

- A Mac with macOS 14 or later. The app runs natively on Apple silicon and Intel.

## Installation

PDF to me is only available as a free community build. It is not notarized by Apple and not available in the App
Store.

1. Download `PDF-to-me-<version>-Community-macOS.zip` and the matching `.sha256` file from
   [GitHub Releases](https://github.com/Hank1210/pdf-to-me/releases).
2. Check the download in Terminal, in the folder that contains both files:

   ```sh
   shasum -a 256 -c PDF-to-me-<version>-Community-macOS.zip.sha256
   ```

   Terminal must report `OK`. Do not install the app if the check fails.
3. Unpack the zip and move "PDF to me" into Applications.
4. Open the app. macOS will say it cannot verify the developer.
5. Go to System Settings → Privacy & Security and click "Open Anyway".

macOS may ask again after an update. The app's data is kept.

Step-by-step instructions, including updating and uninstalling, are in
[COMMUNITY_INSTALLATION_EN.md](COMMUNITY_INSTALLATION_EN.md) (German: [COMMUNITY_INSTALLATION.md](COMMUNITY_INSTALLATION.md)).

You can also build the app yourself (see [Building from source](#building-from-source)).

There is no automatic updater. New versions are published on GitHub Releases; changes are listed in
[CHANGELOG.md](CHANGELOG.md).

## Privacy and security

- **No network connections.** The app does not connect to the internet.

- **Text recognition on your Mac.** Recognized text stays in memory until you save and is written only into the
  new file.

- **No copies of your documents.** The data for crash recovery contains references to your files and the list of
  your changes, not the content of your documents.

- **Passwords** for protected PDFs are kept in memory only and never written to disk.

- **Diagnostic log.** The log at `~/Library/Logs/PDF-to-me/pdf-to-me.log` records what the app does and which
  errors occur. It never records document content, file names or passwords.

Details are in [PRIVACY.md](PRIVACY.md).

## Troubleshooting

- **"PDF to me" cannot be opened.** The app is not notarized. Allow it under System Settings → Privacy & Security →
  "Open Anyway".

- **A PDF cannot be opened.** The file may be damaged. The app shows the reason. Try opening it in Preview; if
  Preview cannot open it either, the file itself is the problem.

- **A file could not be saved.** The check after saving failed. Your original is unchanged. The message shows what
  went wrong.

- **A source file is missing after a restart.** It was moved, renamed or deleted while your work was unsaved. Put
  it back or remove its pages from the document.

## Building from source

The project is a Swift package without an Xcode project. It uses Swift, SwiftUI and AppKit. The only third-party
components are qpdf and libjpeg-turbo (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). Code shared with Scan to
me lives in [DocKit](https://github.com/Hank1210/doc-kit), a separate Swift package under the MIT license that the
Swift Package Manager downloads during the first build.
`Scripts/fetch-qpdf.sh` downloads their source code once, checks it against pinned SHA-256 checksums and builds
static libraries into `Vendor/`, which is not part of the repository. This first build needs an internet connection
and [CMake](https://cmake.org) (`brew install cmake`).

```sh
./Scripts/fetch-qpdf.sh    # once: builds qpdf and libjpeg-turbo into Vendor/
swift test                 # unit tests
./build-app.sh             # builds "build/PDF to me.app" (universal, ad hoc signature)
```

`./Scripts/make-release.sh` runs the tests, builds the app and creates the release zip file with its `.sha256` file
in `build/`.

| Path | Contents |
| --- | --- |
| `Sources/PDFToMeCore/` | All logic, covered by tests: document model, page operations, saving and checks |
| `Sources/QPDFKit/` | C interface to qpdf |
| `Scripts/fetch-qpdf.sh` | Downloads, verifies and builds qpdf and libjpeg-turbo |
| `Scripts/make-icon.swift` | Draws the app icon during the build |
| `Scripts/make-release.sh` | Creates the release zip file and its checksum |
| `Sources/PDFToMeApp/` | User interface, kept thin |
| `Tests/PDFToMeCoreTests/` | Tests, including a corpus of test PDFs |

The test PDFs are generated for testing or come with a free license. Their sources are listed in
`Tests/Corpus/SOURCES.md`.

## Contributing

Issues and pull requests are welcome, especially:

- PDFs that the app handles badly. Please describe the problem or attach a file you are allowed to share. Never
  attach personal documents.

- translations.

Please keep the logic in `PDFToMeCore` with tests, and keep the user interface thin.

## License

[MIT](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
