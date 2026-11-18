#!/bin/zsh
# Baut „PDF to me.app“ (universal, ad hoc signiert) nach build/.
# build ist ein Verweis auf build.noindex: Spotlight indiziert ihn nicht, sonst erscheint jeder Build in der App-Übersicht.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build.noindex
[[ -L build ]] || ln -s build.noindex build

# qpdf und libjpeg-turbo aus Quellcode bauen, falls noch nicht geschehen (braucht beim ersten Mal Internet und cmake).
./Scripts/fetch-qpdf.sh

# Universal-Build für Apple Silicon und Intel (qpdf und libjpeg-turbo liegen bereits universal vor).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product PDFToMeApp "${ARCHS[@]}"

APP="build/PDF to me.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Leere Sprachordner: macOS zeigt Menüs und Dialoge dann in der in der App gewählten Sprache (nach Neustart).
mkdir -p "$APP/Contents/Resources/de.lproj" "$APP/Contents/Resources/en.lproj"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/PDFToMeApp" "$APP/Contents/MacOS/PDFToMeApp"
cp Support/PDFToMe-Info.plist "$APP/Contents/Info.plist"
# Das App-Symbol folgt später; bis dahin zeigt macOS das Standardsymbol.
[[ -f Support/AppIcon.icns ]] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Fertig: $PWD/$APP"
