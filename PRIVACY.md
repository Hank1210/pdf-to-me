# Privacy

PDF to me works entirely on your Mac. It has no account, no analytics, no advertising, no telemetry and no server
operated by the developers.

## No network connections

The app does not connect to the internet. It does not check for updates, does not send crash reports and does not
load anything from the web. Links in a PDF are opened by your default browser only when you click them.

## Your documents

- **The original is never changed.** Saving always creates a new file next to the original or in the folder you
  choose.
- **No copies of your documents.** The app does not keep copies of your documents anywhere else.
- **Failed checks.** If a new file fails the check before saving, it is not placed in the destination folder. It can
  remain in a temporary folder of macOS for diagnosis, which macOS cleans up automatically. If the file would contain
  pages from a password-protected PDF without a password, it is deleted immediately.

## Text recognition

Text recognition runs on your Mac with Apple's Vision framework; nothing is sent anywhere. The recognized text is
kept in memory only while the document is open and is written only into the new file when you save. It is not
stored in the crash recovery data or in the log. After a crash, the marked pages are recognized again.

## Passwords

Passwords for protected PDFs are kept in memory only while the document is open. They are never written to disk, not
in the crash recovery data, the log or the macOS Keychain.

## Data stored on your Mac

| What | Where | Contents |
| --- | --- | --- |
| Crash recovery | `~/Library/Application Support/PDF to me/Sessions/` | One file per document with unsaved changes: references to the source files (file name, a macOS bookmark, a checksum and the page count) and the list of your changes. No document content and no passwords. Readable only by your user account. Deleted when you save or close the document. |
| Diagnostic log | `~/Library/Logs/PDF-to-me/pdf-to-me.log` | What the app does and which errors occur, with technical IDs, page counts and timings. No document content, no file names and no passwords. At most about 4 MB, older entries are deleted automatically. Readable only by your user account. |
| Recent documents and open windows | managed by macOS | macOS keeps the list in "Open Recent" and in the start window, and reopens documents that were open when you quit the app, as for any document-based app. |

You can delete these files at any time. If you delete the crash recovery folder, unsaved changes are lost.

## Sharing a log

If you report a problem, you can attach the diagnostic log. It is designed to contain no document content, but
please look at it before you share it.

Never attach personal documents to a public issue.
