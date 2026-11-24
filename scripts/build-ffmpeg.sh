#!/bin/bash
# בונה ffmpeg + ffprobe סטטיים מהמקור הרשמי, ברישיון LGPL (בלי x264 ושאר רכיבי GPL), לארכיטקטורה אחת.
# הקידוד לוידאו נעשה ב-VideoToolbox של אפל; MP3 דרך LAME (גם הוא LGPL); TLS דרך SecureTransport של המערכת.
# שימוש: scripts/build-ffmpeg.sh <arm64|x86_64> <תיקיית-פלט>
set -euo pipefail

ARCH="$1"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"

# גרסאות וחתימות: כמו בנוסחאות של Homebrew (שמצביעות על המקורות הרשמיים)
FFMPEG_VERSION=9.0.2
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
LAME_VERSION=4.0
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"
LAME_SHA256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
MIN_MACOS=14.0

WORK="$(mktemp -d)"
PREFIX="$WORK/prefix"
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
FLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS -O2"
# רק ספריות שאנחנו בונים כאן, לא מה שמותקן במכונת הבנייה (Homebrew)
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

fetch() {  # fetch <url> <sha256> <file>
  curl -fsSL --retry 3 -o "$WORK/$3" "$1"
  echo "$2  $WORK/$3" | shasum -a 256 -c -
}

fetch "$FFMPEG_URL" "$FFMPEG_SHA256" ffmpeg.tar.xz
fetch "$LAME_URL" "$LAME_SHA256" lame.tar.gz
tar -xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
tar -xzf "$WORK/lame.tar.gz" -C "$WORK"

echo "::group::LAME ($ARCH)"
cd "$WORK/lame-$LAME_VERSION"
HOST_ARGS=()
[ "$ARCH" != "$(uname -m)" ] && HOST_ARGS=(--host="$ARCH-apple-darwin")
CC=clang CFLAGS="$FLAGS" LDFLAGS="$FLAGS" ./configure --prefix="$PREFIX" ${HOST_ARGS[@]+"${HOST_ARGS[@]}"} \
  --disable-shared --enable-static --disable-frontend --disable-gtktest --disable-decoder
make -j"$JOBS" && make install
echo "::endgroup::"

echo "::group::FFmpeg ($ARCH)"
cd "$WORK/ffmpeg-$FFMPEG_VERSION"
CROSS=()
[ "$ARCH" != "$(uname -m)" ] && CROSS=(--enable-cross-compile --target-os=darwin)
./configure --prefix="$WORK/out" --arch="$ARCH" --cc="clang -arch $ARCH" ${CROSS[@]+"${CROSS[@]}"} \
  --extra-cflags="-mmacosx-version-min=$MIN_MACOS -I$PREFIX/include" \
  --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -L$PREFIX/lib" \
  --enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay \
  --disable-autodetect --disable-indevs --disable-outdevs \
  --enable-securetransport --enable-videotoolbox --enable-audiotoolbox \
  --enable-zlib --enable-bzlib --enable-iconv --enable-libmp3lame
make -j"$JOBS"
echo "::endgroup::"

# רק ספריות מערכת מותרות, אחרת זה לא ירוץ על מק של מישהו אחר
for bin in ffmpeg ffprobe; do
  strip "$bin"
  if otool -L "$bin" | tail -n +2 | grep -vE "^\s+(/usr/lib/|/System/Library/)"; then
    echo "::error::$bin links to a non-system library"; exit 1
  fi
done
grep -q "CONFIG_GPL 0" config.h || { echo "::error::build is not LGPL"; exit 1; }

PKG="$WORK/pkg"
mkdir -p "$PKG"
cp ffmpeg ffprobe "$PKG/"
cp COPYING.LGPLv2.1 "$PKG/LICENSE-FFmpeg-LGPL.txt"
cp "$WORK/lame-$LAME_VERSION/COPYING" "$PKG/LICENSE-LAME-LGPL.txt"
{
  echo "FFmpeg $FFMPEG_VERSION ($FFMPEG_URL, sha256 $FFMPEG_SHA256)"
  echo "LAME $LAME_VERSION ($LAME_URL, sha256 $LAME_SHA256)"
  echo "arch: $ARCH, minimum macOS: $MIN_MACOS"
  echo "configure: $(grep -m1 'FFMPEG_CONFIGURATION' config.h | cut -d'"' -f2)"
} > "$PKG/BUILD_INFO.txt"
(cd "$PKG" && zip -q -X "$OUT/ffmpeg-$FFMPEG_VERSION-$ARCH.zip" ./*)
echo "built: $OUT/ffmpeg-$FFMPEG_VERSION-$ARCH.zip"
