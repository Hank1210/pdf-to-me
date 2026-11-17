# Test corpus sources

Every file in this folder must be either generated for testing or published under a license that allows
redistribution. Never add personal or confidential documents, not even temporarily: the repository history will be
public.

## Generated at test time

Most test files are not stored in the repository. `Tests/PDFToMeCoreTests/Support/TestCorpus.swift` generates them
in a temporary folder while the tests run and deletes them afterwards. `CorpusTests` checks that each generated file
has the properties the other tests rely on.

| Generator | What it produces |
| --- | --- |
| `pdf(named:pages:sizes:)` | Text PDF; every page carries the text `<name> page <n>`; optional mixed page sizes |
| `encryptedPDF` | Password-protected PDF (128-bit, user and owner password) |
| `linkedPDF` | Three pages with an outline, an internal link (page 1 to page 3) and an external link |
| `formPDF` | AcroForm with a filled text field and a checked checkbox |
| `scannedPDF` | Image-only page without a text layer |
| `mixedScriptPDF` | Ligatures, umlauts, Hebrew and Arabic (right-to-left) text |
| `truncatedPDF`, `notAPDF`, `emptyFile` | Damaged files that must be rejected |
| `image(named:format:size:)` | PNG, JPEG and HEIC images |

## Files in this folder

None yet. If a problem can only be reproduced with a real-world file, rebuild it with a generator above. Add a
file here only if that is impossible, and list its origin and license in the table below.

| File | Origin | License | Notes |
| --- | --- | --- | --- |
