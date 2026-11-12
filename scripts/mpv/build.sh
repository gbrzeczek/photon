#!/bin/bash
# Builds Photon's own LGPL libmpv and FFmpeg, as dylibs for the app's Frameworks folder.
#
#   scripts/mpv/build.sh [output-dir]
#
# The output, `Vendor/mpv` by default, holds `lib/` with every dylib, universal when ARCHS names more
# than one architecture, `LICENSES/` with each library's license, and `manifest.txt` with the versions,
# commits and the SHA-256 of each dylib. It's kept out of git: the release workflow runs this script,
# and caches its output on this file's hash.
#
# Everything is LGPL or more permissive: FFmpeg without --enable-gpl or --enable-nonfree, mpv with
# -Dgpl=false, and libplacebo, libass, dav1d, FreeType, HarfBuzz and FriBidi. dav1d is there because
# FFmpeg's own AV1 decoder needs hardware, which Macs before M3 don't have. Linking is dynamic, and every
# library keeps its own file, so a user can replace any of them, as the LGPL asks.
#
# Each source is fetched by tag and checked against a pinned commit, so a moved tag fails the build.
#
# Environment:
#   ARCHS      Architectures to build, "arm64" by default. "arm64 x86_64" builds both and joins them.
#   JOBS       Parallel jobs, the number of CPUs by default.
#   WORK_DIR   Where sources and build trees go, `<output>/.work` by default.
#
# Needs Xcode, and meson, ninja, pkgconf and nasm (for x86_64) from Homebrew.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/Vendor/mpv}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="${WORK_DIR:-$OUT/.work}"
ARCHS="${ARCHS:-arm64}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MIN_MACOS=26.0

# name|url|tag|commit
SOURCES=(
    "dav1d|https://code.videolan.org/videolan/dav1d.git|1.5.4|54706fc6bc0cdecab7e9593974a4039cc038fca7"
    "ffmpeg|https://github.com/FFmpeg/FFmpeg.git|n8.1.3|1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7"
    "freetype|https://github.com/freetype/freetype.git|VER-2-14-3|0a0221a1347e2f1e07c395263540026e9a0aa7c7"
    "harfbuzz|https://github.com/harfbuzz/harfbuzz.git|15.1.0|3df40d9b98d6b32f0e4288d4ecfbb158ddb3a372"
    "fribidi|https://github.com/fribidi/fribidi.git|v1.0.16|68162babff4f39c4e2dc164a5e825af93bda9983"
    "libass|https://github.com/libass/libass.git|0.17.4|bbb3c7f1570a4a021e52683f3fbdf74fe492ae84"
    "libplacebo|https://code.videolan.org/videolan/libplacebo.git|v7.360.1|cee9b076f2c63104ccfd497fa79c39a867293ec4"
    "mpv|https://github.com/mpv-player/mpv.git|v0.41.0|41f6a645068483470267271e1d09966ca3b9f413"
)

for tool in meson ninja pkg-config xcrun; do
    command -v "$tool" >/dev/null || { echo "error: $tool is missing. brew install meson ninja pkgconf nasm" >&2; exit 1; }
done

SDK="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

fetch() {
    local name="$1" url="$2" tag="$3" commit="$4" dir="$WORK/src/$1"
    if [ ! -d "$dir/.git" ]; then
        rm -rf "$dir"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" \
            --recurse-submodules --shallow-submodules "$url" "$dir"
    fi
    local head
    head="$(git -C "$dir" rev-parse HEAD)"
    if [ "$commit" != "PIN" ] && [ "$head" != "$commit" ]; then
        echo "error: $name $tag is at $head, expected $commit" >&2
        exit 1
    fi
    echo "$name $tag $head" >> "$WORK/versions.txt"
}

# Writes a meson cross file for one architecture, so that x86_64 builds on Apple silicon and back.
cross_file() {
    local arch="$1" file="$WORK/cross-$1.txt"
    local cpu_family="$arch"
    [ "$arch" = arm64 ] && cpu_family=aarch64
    cat > "$file" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
objc = ['clang', '-arch', '$arch']
objcpp = ['clang++', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$MIN_MACOS']
cpp_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$MIN_MACOS']
objc_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$MIN_MACOS']
c_link_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$MIN_MACOS', '-Wl,-headerpad_max_install_names']
cpp_link_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$MIN_MACOS', '-Wl,-headerpad_max_install_names']
objc_link_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$MIN_MACOS', '-Wl,-headerpad_max_install_names']

[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'
EOF
    echo "$file"
}

meson_build() {
    local name="$1" arch="$2"
    shift 2
    local prefix="$WORK/prefix-$arch" build="$WORK/build-$arch/$name"
    if [ -f "$build/.done" ]; then return; fi
    rm -rf "$build"
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="" \
        meson setup "$build" "$WORK/src/$name" --cross-file "$(cross_file "$arch")" \
        --prefix "$prefix" --libdir lib --buildtype release -Ddefault_library=shared -Db_ndebug=true "$@"
    meson compile -C "$build" -j "$JOBS"
    meson install -C "$build" --quiet
    touch "$build/.done"
}

build_ffmpeg() {
    local arch="$1" prefix="$WORK/prefix-$arch" build="$WORK/build-$arch/ffmpeg"
    if [ -f "$build/.done" ]; then return; fi
    rm -rf "$build"
    mkdir -p "$build"
    local ffarch="$arch"
    [ "$arch" = arm64 ] && ffarch=aarch64
    if [ "$arch" = x86_64 ]; then
        command -v nasm >/dev/null || { echo "error: nasm is missing, for x86_64" >&2; exit 1; }
    fi
    (
        cd "$build"
        export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=""
        # No --enable-gpl and no --enable-nonfree: the result is LGPL 2.1 or later.
        # No protocols at all: mpv hands FFmpeg every byte through its own stream, which Photon serves
        # through the volume's I/O scheduler, so FFmpeg has no way to open a file by itself.
        "$WORK/src/ffmpeg/configure" \
            --prefix="$prefix" \
            --enable-cross-compile --target-os=darwin --arch="$ffarch" \
            --cc="clang -arch $arch" --cxx="clang++ -arch $arch" \
            --sysroot="$SDK" \
            --extra-cflags="-mmacosx-version-min=$MIN_MACOS" \
            --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -Wl,-headerpad_max_install_names" \
            --install-name-dir='@rpath' \
            --enable-shared --disable-static \
            --enable-pic \
            --disable-programs --disable-doc --disable-debug \
            --disable-network --disable-protocols \
            --disable-avdevice --disable-indevs --disable-outdevs \
            --disable-encoders --disable-muxers \
            --disable-sdl2 --disable-xlib --disable-libxcb --disable-iconv \
            --disable-securetransport \
            --enable-videotoolbox --enable-audiotoolbox \
            --enable-libdav1d
        make -j "$JOBS"
        make install
    )
    touch "$build/.done"
}

build_arch() {
    local arch="$1"
    meson_build dav1d "$arch" -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false
    build_ffmpeg "$arch"
    # FreeType without HarfBuzz first, then HarfBuzz with it: libass needs both, and HarfBuzz's
    # FreeType functions.
    meson_build freetype "$arch" -Dharfbuzz=disabled -Dpng=disabled -Dbrotli=disabled -Dbzip2=disabled \
        -Dzlib=disabled -Dtests=disabled
    meson_build harfbuzz "$arch" -Dfreetype=enabled -Dsubset=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dpng=disabled -Dzlib=disabled -Dchafa=disabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dicu=disabled -Dcoretext=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled \
        -Dintrospection=disabled
    meson_build fribidi "$arch" -Ddocs=false -Dbin=false -Dtests=false
    meson_build libass "$arch" -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled \
        -Dasm=disabled -Drequire-system-font-provider=false -Dlibunibreak=disabled
    meson_build libplacebo "$arch" -Dvulkan=disabled -Dopengl=enabled -Dd3d11=disabled -Dglslang=disabled \
        -Dshaderc=disabled -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled -Ddemos=false -Dtests=false \
        -Dxxhash=disabled -Dunwind=disabled
    # LGPL mpv as a library only. Lua and JavaScript are off, because their scripts would need a JIT
    # entitlement under the hardened runtime, and Photon has no use for them. plain-gl is the OpenGL
    # render API without mpv's own windows, which is what drawing into a CAOpenGLLayer needs.
    meson_build mpv "$arch" -Dgpl=false -Dlibmpv=true -Dcplayer=false -Dtests=false -Dfuzzers=false \
        -Dlua=disabled -Djavascript=disabled -Dcplugins=disabled \
        -Dcocoa=disabled -Dgl-cocoa=enabled -Dswift-build=disabled -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled \
        -Dmacos-touchbar=disabled -Dvulkan=disabled -Dgl=enabled -Dplain-gl=enabled \
        -Dcoreaudio=disabled -Daudiounit=disabled -Davfoundation=enabled \
        -Dvideotoolbox-gl=enabled -Dvideotoolbox-pl=disabled \
        -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled -Duchardet=disabled \
        -Drubberband=disabled -Dlcms2=disabled -Dzimg=disabled -Djpeg=disabled -Dsdl2-audio=disabled \
        -Dsdl2-video=disabled -Dsdl2-gamepad=disabled -Diconv=disabled -Djavascript=disabled \
        -Dhtml-build=disabled -Dmanpage-build=disabled -Dpdf-build=disabled
}

# Replaces `from` with `to` in a source file once, and fails if neither is there, so a new mpv whose
# build changed can't quietly build without the change.
patch_once() {
    python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
if new not in text:
    if old not in text:
        sys.exit(f"error: a patch to {path} no longer applies")
    open(path, "w").write(text.replace(old, new, 1))
PY
}

# Two changes to mpv's build, neither to its code. Photon brings its own layer and never uses mpv's
# windows, so Cocoa stays off, because it needs mpv's Swift code.
# - VideoToolbox's OpenGL interop is only offered with gl-cocoa, which mpv ties to Cocoa. The interop
#   needs only the OpenGL framework.
# - The AVFoundation audio output uses two small C helpers that are only compiled with Cocoa.
patch_sources() {
    local file="$WORK/src/mpv/meson.build"
    patch_once "$file" \
        "    features['cocoa'] and GL.found() and gl_allowed," \
        "    GL.found() and gl_allowed,"
    patch_once "$file" \
        "if features['avfoundation']
    sources += files('audio/out/ao_coreaudio_properties.c')
endif" \
        "if features['avfoundation']
    sources += files('audio/out/ao_coreaudio_properties.c')
    if not features['cocoa']
        sources += files('osdep/utils-mac.c')
    endif
endif"
}

# Loads the finished libmpv as the app will, resolving every symbol, and starts a core, so a library
# that links but can't load fails here rather than in the app.
smoke_test() {
    local lib="$1" test_dir="$WORK/smoke"
    mkdir -p "$test_dir"
    cat > "$test_dir/smoke.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    void *(*create)(void) = dlsym(lib, "mpv_create");
    int (*initialize)(void *) = dlsym(lib, "mpv_initialize");
    int (*set_option)(void *, const char *, const char *) = dlsym(lib, "mpv_set_option_string");
    void (*destroy)(void *) = dlsym(lib, "mpv_terminate_destroy");
    if (!create || !initialize || !set_option || !destroy) { fprintf(stderr, "missing symbols\n"); return 1; }
    void *mpv = create();
    if (!mpv) { fprintf(stderr, "mpv_create failed\n"); return 1; }
    set_option(mpv, "config", "no");
    set_option(mpv, "ao", "avfoundation");
    set_option(mpv, "vo", "libmpv");
    if (initialize(mpv) < 0) { fprintf(stderr, "mpv_initialize failed\n"); return 1; }
    destroy(mpv);
    puts("libmpv loads and starts");
    return 0;
}
C
    clang -o "$test_dir/smoke" "$test_dir/smoke.c"
    "$test_dir/smoke" "$lib"
}

# Makes every dylib find its siblings through @rpath, from wherever it's loaded.
relink() {
    local lib_dir="$1"
    for dylib in "$lib_dir"/*.dylib; do
        [ -L "$dylib" ] && continue
        local name
        name="$(basename "$dylib")"
        install_name_tool -id "@rpath/$name" "$dylib"
        otool -L "$dylib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
            case "$dep" in
                /usr/lib/* | /System/*) ;;
                @rpath/*) ;;
                *) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dylib" ;;
            esac
        done
        if ! otool -l "$dylib" | grep -q "path @loader_path "; then
            install_name_tool -add_rpath @loader_path "$dylib"
        fi
    done
}

# Copies the libraries that libmpv needs, and nothing else, following symlinks to the real files.
collect() {
    local arch="$1" dest="$2" prefix="$WORK/prefix-$arch/lib"
    rm -rf "$dest"
    mkdir -p "$dest"
    local queue=("libmpv.2.dylib") seen=" "
    while [ ${#queue[@]} -gt 0 ]; do
        local name="${queue[0]}"
        queue=("${queue[@]:1}")
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        cp -L "$prefix/$name" "$dest/$name"
        chmod 644 "$dest/$name"
        while read -r dep; do
            local base
            base="$(basename "$dep")"
            [ -e "$prefix/$base" ] && queue+=("$base")
        done < <(otool -L "$prefix/$name" | tail -n +2 | awk '{print $1}' | grep -v '^/usr/lib\|^/System')
    done
    relink "$dest"
}

rm -f "$WORK/versions.txt"
mkdir -p "$WORK/src"
for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url tag commit <<< "$entry"
    fetch "$name" "$url" "$tag" "$commit"
done
if [ "${FETCH_ONLY:-0}" = 1 ]; then cat "$WORK/versions.txt"; exit 0; fi

patch_sources

for arch in $ARCHS; do
    build_arch "$arch"
    collect "$arch" "$WORK/lib-$arch"
done

rm -rf "$OUT/lib" "$OUT/LICENSES"
mkdir -p "$OUT/lib" "$OUT/LICENSES"
set -- $ARCHS
for dylib in "$WORK/lib-$1"/*.dylib; do
    name="$(basename "$dylib")"
    if [ $# -gt 1 ]; then
        inputs=()
        for arch in $ARCHS; do inputs+=("$WORK/lib-$arch/$name"); done
        lipo -create "${inputs[@]}" -output "$OUT/lib/$name"
    else
        cp "$dylib" "$OUT/lib/$name"
    fi
done

# Each library's license, shipped beside the dylibs.
cp "$WORK/src/ffmpeg/COPYING.LGPLv2.1" "$OUT/LICENSES/FFmpeg-LGPL-2.1.txt"
cp "$WORK/src/mpv/LICENSE.LGPL" "$OUT/LICENSES/mpv-LGPL-2.1.txt"
cp "$WORK/src/libplacebo/LICENSE" "$OUT/LICENSES/libplacebo-LGPL-2.1.txt"
cp "$WORK/src/libass/COPYING" "$OUT/LICENSES/libass-ISC.txt"
cp "$WORK/src/freetype/docs/FTL.TXT" "$OUT/LICENSES/FreeType-FTL.txt"
cp "$WORK/src/harfbuzz/COPYING" "$OUT/LICENSES/HarfBuzz-MIT.txt"
cp "$WORK/src/fribidi/COPYING" "$OUT/LICENSES/FriBidi-LGPL-2.1.txt"
cp "$WORK/src/dav1d/COPYING" "$OUT/LICENSES/dav1d-BSD-2-Clause.txt"

smoke_test "$OUT/lib/libmpv.2.dylib"

{
    echo "Photon's libmpv build, by scripts/mpv/build.sh"
    echo "Architectures: $ARCHS"
    echo "Minimum macOS: $MIN_MACOS"
    echo
    cat "$WORK/versions.txt"
    echo
    (cd "$OUT/lib" && shasum -a 256 ./*.dylib)
} > "$OUT/manifest.txt"

echo "Built $(ls "$OUT/lib" | wc -l | tr -d ' ') dylibs in $OUT/lib for $ARCHS"
