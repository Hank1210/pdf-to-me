# Third-Party Notices

PDF to me is available under the [MIT License](LICENSE). This file lists the separately licensed components it uses.

## Bundled components

These components are built from source by `Scripts/fetch-qpdf.sh` (pinned versions, verified SHA-256 checksums)
and linked statically into the app. Their full license texts are in [`THIRD_PARTY_LICENSES/`](THIRD_PARTY_LICENSES).

### qpdf 12.4.2

- Source: <https://github.com/qpdf/qpdf>, release `v12.4.2`
- Copyright (c) 2005-2021 Jay Berkenbilt, 2022-2026 Jay Berkenbilt and Manfred Holger
- License: Apache License 2.0 ([`qpdf-LICENSE.txt`](THIRD_PARTY_LICENSES/qpdf-LICENSE.txt)); notices for the
  included Rijndael (public domain) and sha2 (sphlib, MIT-style) code in
  [`qpdf-NOTICE.md`](THIRD_PARTY_LICENSES/qpdf-NOTICE.md)
- Used for: writing new PDF files from pages of existing ones (merge, split, reorder, rotate) while keeping links,
  the table of contents and form fields, and for password protection
- Built with qpdf's native crypto provider; not modified

### libjpeg-turbo 3.2.1

- Source: <https://github.com/libjpeg-turbo/libjpeg-turbo>, release `3.2.1`
- License: IJG License and Modified (3-clause) BSD License
  ([`libjpeg-turbo-LICENSE.md`](THIRD_PARTY_LICENSES/libjpeg-turbo-LICENSE.md),
  [`libjpeg-turbo-README.ijg`](THIRD_PARTY_LICENSES/libjpeg-turbo-README.ijg))
- Required by qpdf for JPEG image data; only the libjpeg API library is built (no SIMD, no TurboJPEG API, no tools)
- This software is based in part on the work of the Independent JPEG Group.

### zlib

PDF to me uses the zlib library supplied with macOS through qpdf. It is not bundled with the app.

## Apple frameworks

PDF to me uses system frameworks supplied with macOS, including AppKit, SwiftUI, PDFKit, Vision, CoreGraphics,
ImageIO, UniformTypeIdentifiers and Security. They are not bundled with the app. Their use is governed by Apple's
applicable software license terms.
