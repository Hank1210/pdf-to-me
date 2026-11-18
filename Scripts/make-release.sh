#!/bin/zsh
# Erzeugt das Release-Archiv der Community-App: build/PDF-to-me-<Version>.zip und die zugehörige .sha256-Datei.
# Voraussetzungen: sauberes Arbeitsverzeichnis und grüne Tests. Die Archive werden nie committet (.gitignore).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Abbruch: Das Arbeitsverzeichnis enthält nicht committete Änderungen." >&2
    exit 1
fi

swift test
./build-app.sh

APP="build/PDF to me.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# Die App muss für beide Architekturen gebaut und gültig signiert sein.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/PDFToMeApp")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "Abbruch: kein Universal-Build ($ARCHS)." >&2; exit 1; }
codesign --verify --strict "$APP"

ZIP="PDF-to-me-$VERSION.zip"
rm -f "build/$ZIP" "build/$ZIP.sha256"
# ditto erhält Signatur und Dateiattribute des App-Pakets.
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$ZIP"
# Die Prüfsummendatei nennt nur den Dateinamen, damit `shasum -c` im Download-Ordner funktioniert.
(cd build && shasum -a 256 "$ZIP" > "$ZIP.sha256")

echo "Fertig:"
echo "  $PWD/build/$ZIP"
echo "  $PWD/build/$ZIP.sha256"
cat "build/$ZIP.sha256"
