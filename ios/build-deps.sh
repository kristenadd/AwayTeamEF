#!/bin/sh
# Build the libraries the iOS app bundles, for one SDK (device or Simulator):
#   SDL2 (the API the engine uses; the desktop builds use sdl2-compat on SDL3, which
#   does not build for iOS), shared;
#   the minimal LGPL FFmpeg for Bink cinematics (as macos/build-ffmpeg.sh), shared;
#   MoltenVK from Khronos's official release (the dynamic xcframework).
#
#   ios/build-deps.sh                 ->  build-ios-deps/iphoneos/install
#   SDK=iphonesimulator ios/build-deps.sh  ->  build-ios-deps/iphonesimulator/install
#
# MIN_IOS (default 15.0) is the deployment target. Tarballs are cached in build-deps/,
# build-ffmpeg/ and build-ios-deps/dl/ and checked against the pins below / deps/versions.sh.
set -eu

SDK="${SDK:-iphoneos}"
MIN_IOS="${MIN_IOS:-15.0}"
case "$SDK" in
	iphoneos) MINFLAG="-miphoneos-version-min=$MIN_IOS"; MVK_SLICE=ios-arm64 ;;
	iphonesimulator) MINFLAG="-mios-simulator-version-min=$MIN_IOS"; MVK_SLICE=ios-arm64_x86_64-simulator ;;
	*) echo "SDK must be iphoneos or iphonesimulator" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/deps/versions.sh"	# shared pins (FFmpeg)
SDL2_IOS_VERSION="2.32.10"
SDL2_IOS_SHA256="5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165"
MOLTENVK_VERSION="1.4.2"
MOLTENVK_SHA256="562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276"	# MoltenVK-all.tar

OUT="$ROOT/build-ios-deps"
DL="$OUT/dl"
WORK="$OUT/$SDK/src"
PREFIX="$OUT/$SDK/install"
JOBS="$(sysctl -n hw.ncpu)"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"

mkdir -p "$DL" "$WORK"

# fetch DIR NAME URL SHA256: download (once) into DIR and verify; prints the tarball path
fetch() {
	tarball="$1/$2"
	if [ ! -f "$tarball" ]; then
		echo "Downloading $2" >&2
		curl -fL -o "$tarball.part" "$3"
		mv "$tarball.part" "$tarball"
	fi
	echo "$4  $tarball" | shasum -a 256 -c - >/dev/null ||
		{ echo "checksum mismatch for $tarball" >&2; exit 1; }
	echo "$tarball"
}

cmake_build() {
	src="$1"; shift
	cmake -S "$src" -B "$src/_build" -G Ninja \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT="$SDK" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$PREFIX" \
		-DCMAKE_PREFIX_PATH="$PREFIX" \
		-DCMAKE_FIND_ROOT_PATH="$PREFIX" \
		"$@"
	cmake --build "$src/_build" -j"$JOBS"
	cmake --install "$src/_build"
	rm -rf "$src"
}

rm -rf "$PREFIX"

# ---- SDL2 (real SDL2: sdl2-compat does not build for iOS) ----
t="$(fetch "$DL" "SDL2-$SDL2_IOS_VERSION.tar.gz" \
	"https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_IOS_VERSION/SDL2-$SDL2_IOS_VERSION.tar.gz" "$SDL2_IOS_SHA256")"
rm -rf "$WORK/SDL2-$SDL2_IOS_VERSION" && tar -xzf "$t" -C "$WORK"
cmake_build "$WORK/SDL2-$SDL2_IOS_VERSION" -DSDL_SHARED=ON -DSDL_STATIC=OFF \
	-DSDL_TEST=OFF -DSDL2_DISABLE_SDL2MAIN=ON -DSDL_OPENGLES=OFF -DSDL_OPENGL=OFF

# ---- FFmpeg (Bink only, LGPL; see macos/build-ffmpeg.sh) ----
t="$(fetch "$ROOT/build-ffmpeg" "ffmpeg-$FFMPEG_VERSION.tar.xz" \
	"https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256")"
rm -rf "$WORK/ffmpeg-$FFMPEG_VERSION" && tar -xJf "$t" -C "$WORK"
(
	cd "$WORK/ffmpeg-$FFMPEG_VERSION"
	./configure \
		--prefix="$PREFIX" \
		--install-name-dir='@rpath' \
		--enable-cross-compile --target-os=darwin --arch=arm64 \
		--cc="$CC" --sysroot="$SYSROOT" \
		--extra-cflags="-arch arm64 $MINFLAG" --extra-ldflags="-arch arm64 $MINFLAG" \
		--enable-shared --disable-static \
		--disable-programs --disable-doc --disable-network \
		--disable-autodetect --disable-everything \
		--disable-avdevice --disable-avfilter --disable-swresample \
		--enable-avformat --enable-avcodec --enable-swscale \
		--enable-demuxer=bink \
		--enable-decoder=bink,binkaudio_rdft,binkaudio_dct
	make -j"$JOBS"
	make install
	grep -q 'FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h ||
		{ echo "FFmpeg was not configured as LGPL-2.1-or-later" >&2; exit 1; }
)
rm -rf "$WORK/ffmpeg-$FFMPEG_VERSION"

# ---- MoltenVK (official release; the dynamic framework for this SDK) ----
t="$(fetch "$DL" "MoltenVK-all.tar" \
	"https://github.com/KhronosGroup/MoltenVK/releases/download/v$MOLTENVK_VERSION/MoltenVK-all.tar" "$MOLTENVK_SHA256")"
rm -rf "$WORK/mvk" && mkdir -p "$WORK/mvk"
tar -xf "$t" -C "$WORK/mvk" "MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/$MVK_SLICE" MoltenVK/LICENSE
mkdir -p "$PREFIX/Frameworks"
cp -R "$WORK/mvk/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/$MVK_SLICE/MoltenVK.framework" "$PREFIX/Frameworks/"
cp "$WORK/mvk/MoltenVK/LICENSE" "$PREFIX/MoltenVK-LICENSE"
rm -rf "$WORK/mvk" "$WORK"

echo "Built SDL2 $SDL2_IOS_VERSION, FFmpeg $FFMPEG_VERSION and MoltenVK $MOLTENVK_VERSION for $SDK (iOS >= $MIN_IOS) in $PREFIX"
