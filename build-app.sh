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
# App-Symbol: wird aus Scripts/make-icon.swift gezeichnet, nicht als Binärdatei im Repo abgelegt.
ICONSET="build.noindex/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift Scripts/make-icon.swift "build.noindex/AppIcon-1024.png"
for px in 16 32 128 256 512; do
    sips -z $px $px "build.noindex/AppIcon-1024.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "build.noindex/AppIcon-1024.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Fertig: $PWD/$APP"
