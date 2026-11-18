# Installing PDF to me Community

[Deutsche Fassung](COMMUNITY_INSTALLATION.md)

PDF to me is free and only available as a community build. It is ad hoc signed and not notarized by Apple, so macOS
shows a security warning the first time you open it.

Requirements: a Mac with macOS 14 or later, with Apple silicon or Intel.

## Check the download

1. From the same [GitHub release](https://github.com/Hank1210/pdf-to-me/releases), download the zip file
   `PDF-to-me-<version>-Community-macOS.zip` and the `.sha256` file with the same name.
2. Open Terminal, go to the download folder and check the archive, for example for 1.0.0:

   ```sh
   cd ~/Downloads
   shasum -a 256 -c PDF-to-me-1.0.0-Community-macOS.zip.sha256
   ```

3. Terminal must report `OK`. Do not install the app if the check fails.

## Install

1. Unpack the zip file.
2. Drag "PDF to me" into the Applications folder.
3. Double-click the app. macOS says it cannot verify the app. Click "Done" or "OK".
4. Open System Settings → Privacy & Security. Near the bottom there is a note about "PDF to me". Click "Open Anyway"
   and confirm with your password or Touch ID.
5. Confirm with "Open" in the next dialog.

On macOS 14 there is a shorter way: in Applications, Control-click "PDF to me", choose "Open" and confirm with "Open"
again.

Only allow the app if you downloaded it from the project's GitHub page and the checksum matches.

## First start

The app needs no setup, no account and no permissions. It shows a start window: drop a PDF on it, click
"Open File…" or choose a recently used file.

## Update

There is no automatic updater. New versions are published on GitHub Releases.

1. Save your work and quit PDF to me with ⌘Q.
2. Check and unpack the new version as described above.
3. Drag "PDF to me" into Applications and replace the old app.
4. macOS may ask you to allow the app again as described under "Install", because every community build has a new
   signature.

The app's data is kept, including the backup of unsaved work.

## Uninstall

1. Quit PDF to me and move the app from Applications to the Trash.
2. To remove the app's data as well, delete these folders:
   - `~/Library/Application Support/PDF to me`
   - `~/Library/Logs/PDF-to-me`

Your PDFs are not affected.

## Build it yourself

Instead of downloading the community build, you can build the app from source. See
[Building from source](README.md#building-from-source) in the README.
