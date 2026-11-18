#!/bin/zsh
# Lädt qpdf und libjpeg-turbo als Quellcode (Version und SHA-256 fest), baut daraus statische Universal-Bibliotheken
# (arm64 und x86_64) und legt sie nach Vendor/qpdf/. Vendor/ ist nicht im Repo; es landen keine Binärdateien im Repo.
#
# Braucht cmake (z. B. „brew install cmake“). Läuft nur, wenn Vendor/qpdf fehlt oder eine andere Version enthält.
set -euo pipefail
cd "$(dirname "$0")/.."

QPDF_VERSION=12.4.2
QPDF_SHA256=8a58af5b6141319287c1883bec8bd1bd545b7567b7fc5e6ce5d25a1c85f36397
JPEG_VERSION=3.2.1
JPEG_SHA256=c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f

VENDOR="$PWD/Vendor/qpdf"
STAMP="qpdf $QPDF_VERSION, libjpeg-turbo $JPEG_VERSION"
if [[ -f "$VENDOR/VERSION" && "$(cat "$VENDOR/VERSION")" == "$STAMP" ]]; then
    exit 0
fi

if ! command -v cmake >/dev/null; then
    echo "cmake fehlt. Installieren mit: brew install cmake" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/downloads" "$WORK/src"

download() {
    local url=$1 sha=$2 file="$WORK/downloads/${1:t}"
    echo "Lade ${url:t} …"
    curl -fsSL -o "$file" "$url"
    if [[ "$(shasum -a 256 "$file" | cut -d ' ' -f 1)" != "$sha" ]]; then
        echo "Prüfsumme von ${url:t} stimmt nicht. Abbruch." >&2
        exit 1
    fi
    tar -xzf "$file" -C "$WORK/src"
}

download "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/libjpeg-turbo-$JPEG_VERSION.tar.gz" \
    "$JPEG_SHA256"
download "https://github.com/qpdf/qpdf/releases/download/v$QPDF_VERSION/qpdf-$QPDF_VERSION.tar.gz" "$QPDF_SHA256"

COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
)

# libjpeg-turbo: nur die statische Bibliothek; ohne SIMD, weil sie sonst nicht in einem Durchgang universal baut.
echo "Baue libjpeg-turbo …"
cmake -S "$WORK/src/libjpeg-turbo-$JPEG_VERSION" -B "$WORK/build-jpeg" "${COMMON[@]}" \
    -DCMAKE_INSTALL_PREFIX="$WORK/jpeg" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF \
    -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF >/dev/null
cmake --build "$WORK/build-jpeg" -j 8 >/dev/null
cmake --install "$WORK/build-jpeg" >/dev/null

# qpdf: statisch, eingebaute Verschlüsselung (kein OpenSSL/GnuTLS), zlib von macOS, libjpeg von oben.
echo "Baue qpdf …"
# pkg-config nur auf das eben gebaute libjpeg-turbo richten, damit keine Homebrew-Version gefunden wird.
PKG_CONFIG_LIBDIR="$(ls -d "$WORK"/jpeg/lib*/pkgconfig)" \
cmake -S "$WORK/src/qpdf-$QPDF_VERSION" -B "$WORK/build-qpdf" "${COMMON[@]}" \
    -DCMAKE_INSTALL_PREFIX="$WORK/qpdf" -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DREQUIRE_CRYPTO_NATIVE=ON -DUSE_IMPLICIT_CRYPTO=OFF -DBUILD_DOC=OFF \
    -DLIBJPEG_H_PATH="$WORK/jpeg/include" >/dev/null
grep -q "$WORK/jpeg/include" "$WORK/build-qpdf/CMakeCache.txt" || {
    echo "qpdf hat nicht das eigene libjpeg-turbo gefunden. Abbruch." >&2
    exit 1
}
cmake --build "$WORK/build-qpdf" -j 8 --target libqpdf >/dev/null

rm -rf "$VENDOR"
mkdir -p "$VENDOR/lib" "$VENDOR/include" "$VENDOR/licenses"
cp "$(ls "$WORK"/jpeg/lib*/libjpeg.a)" "$VENDOR/lib/libjpeg.a"
cp "$WORK/build-qpdf/libqpdf/libqpdf.a" "$VENDOR/lib/libqpdf.a"
cp -R "$WORK/src/qpdf-$QPDF_VERSION/include/qpdf" "$VENDOR/include/qpdf"
cp "$WORK"/build-qpdf/libqpdf/qpdf/*.h "$VENDOR/include/qpdf/" 2>/dev/null || true
cp "$WORK/src/qpdf-$QPDF_VERSION/LICENSE.txt" "$VENDOR/licenses/qpdf-LICENSE.txt"
cp "$WORK/src/qpdf-$QPDF_VERSION/NOTICE.md" "$VENDOR/licenses/qpdf-NOTICE.md"
cp "$WORK/src/libjpeg-turbo-$JPEG_VERSION/LICENSE.md" "$VENDOR/licenses/libjpeg-turbo-LICENSE.md"
cp "$WORK/src/libjpeg-turbo-$JPEG_VERSION/README.ijg" "$VENDOR/licenses/libjpeg-turbo-README.ijg"
echo "$STAMP" > "$VENDOR/VERSION"

echo "Fertig: $VENDOR ($STAMP)"
lipo -info "$VENDOR/lib/libqpdf.a" "$VENDOR/lib/libjpeg.a"
