#!/bin/sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=${WINE_CX_ROOT:-"$REPO/build/wine-crossover"}
URL=https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz
SHA=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872
ARCHIVE="$ROOT/source-cache/crossover-sources-26.3.0.tar.gz"
SOURCE="$ROOT/source-root/sources/wine"
BUILD="$ROOT/build-x64"
PREFIX="$ROOT/host"
PATCH="$REPO/patches/wine-crossover/0001-msync-registration-wake.patch"
GST=${WINE_CX_GSTREAMER_ROOT:-"$ROOT/package/stage/wine/lib/GStreamer.framework/Versions/1.0"}
MP=${WINE_CX_DEPS_PREFIX:-"/Users/hanbinnoh/Documents/yaagl-dx12/build/wine-p3/deps/macports/opt/local"}
MINGW=${WINE_CX_MINGW:-/opt/llvm-mingw-20260616-ucrt-macos-universal/bin/clang}
PKGCONFIG=${WINE_CX_PKG_CONFIG:-/opt/homebrew/bin/pkg-config}
JOBS=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)
ACTION=${1:-all}

hash_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d ' ' -f 1; }
fetch() {
    /bin/mkdir -p "$ROOT/source-cache" "$ROOT/source-root"
    if [ ! -f "$ARCHIVE" ] || [ "$(hash_file "$ARCHIVE")" != "$SHA" ]; then
        /usr/bin/curl -fL --retry 3 -o "$ARCHIVE.tmp" "$URL"
        [ "$(hash_file "$ARCHIVE.tmp")" = "$SHA" ] || { /bin/rm -f "$ARCHIVE.tmp"; echo "source checksum mismatch" >&2; exit 1; }
        /bin/mv "$ARCHIVE.tmp" "$ARCHIVE"
    fi
    [ "$(hash_file "$ARCHIVE")" = "$SHA" ] || { echo "source checksum mismatch" >&2; exit 1; }
    if [ ! -f "$SOURCE/VERSION" ]; then
        COPYFILE_DISABLE=1 /usr/bin/tar -xzf "$ARCHIVE" -C "$ROOT/source-root"
    fi
    [ "$(/bin/cat "$SOURCE/VERSION")" = "Wine version 11.0" ] || { echo "unexpected Wine source version" >&2; exit 1; }
}
prepare() {
    fetch
    [ -s "$PATCH" ] || { echo "missing MSync correction: $PATCH" >&2; exit 1; }
    if /usr/bin/patch -d "$SOURCE" -p1 --dry-run -R < "$PATCH" >/dev/null 2>&1; then
        :
    else
        /usr/bin/patch -d "$SOURCE" -p1 --forward < "$PATCH"
    fi
}
configure_build() {
    [ -d "$GST/lib/pkgconfig" ] || { echo "missing x86_64 GStreamer SDK: $GST" >&2; exit 1; }
    [ -x "$MINGW" ] || { echo "missing llvm-mingw: $MINGW" >&2; exit 1; }
    [ -f "$MP/lib/pkgconfig/gnutls.pc" ] || { echo "missing pinned x86_64 dependency SDK: $MP" >&2; exit 1; }
    SDKROOT=${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}
    export SDKROOT MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0}
    export ac_cv_lib_soname_vulkan=libMoltenVK.dylib
    export PATH="/opt/homebrew/opt/bison/bin:/opt/llvm-mingw-20260616-ucrt-macos-universal/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export PKG_CONFIG="$PKGCONFIG" PKG_CONFIG_PATH="$MP/lib/pkgconfig:$GST/lib/pkgconfig" PKG_CONFIG_LIBDIR="$MP/lib/pkgconfig:$GST/lib/pkgconfig"
    export CPPFLAGS="-I$MP/include ${CPPFLAGS:-}"
    export CFLAGS="-arch x86_64 -I$GST/include ${CFLAGS:-}"
    export LDFLAGS="-arch x86_64 -L$MP/lib -L$GST/lib -Wl,-rpath,$MP/lib -Wl,-rpath,@loader_path/../lib/GStreamer.framework/Versions/1.0/lib ${LDFLAGS:-}"
    /bin/mkdir -p "$BUILD" "$PREFIX"
    cd "$BUILD"
    if [ ! -f "$BUILD/config.status" ] || ! /usr/bin/grep -q 'ac_cv_lib_soname_vulkan=libMoltenVK.dylib' "$BUILD/config.log"; then
        arch -x86_64 "$SOURCE/configure" \
          --prefix="$PREFIX" --disable-tests --enable-win64 --enable-archs=i386,x86_64 \
          --with-mingw="$MINGW" --with-coreaudio --with-cups --with-freetype --with-gettext \
          --with-gnutls --with-gstreamer --with-ffmpeg --with-sdl --with-pthread \
          --with-pcsclite --with-opencl --without-pcap --without-inotify --with-vulkan \
          --without-alsa --without-capi --without-dbus --without-fontconfig --without-gettextpo \
          --without-gphoto --without-gssapi --without-krb5 --without-netapi --without-opengl \
          --without-oss --without-pulse --without-sane --without-udev --without-usb \
          --without-v4l2 --without-wayland --without-x --disable-winebth_sys
    fi
    arch -x86_64 /usr/bin/make -C "$BUILD" -j"$JOBS"
    arch -x86_64 /usr/bin/make -C "$BUILD" install
}
case "$ACTION" in
 fetch) fetch ;;
 prepare) prepare ;;
 build|all) prepare; configure_build ;;
 *) echo "usage: $0 {fetch|prepare|build|all}" >&2; exit 2 ;;
esac
