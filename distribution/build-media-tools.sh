#!/bin/bash
# Build the standalone GPL FFmpeg programs from the two source archives in the release.
set -eo pipefail
arch=${1:?arm64 or x86_64}
src=${2:?directory with ffmpeg-8.1.3.tar.xz and x264.tar.gz}
work=${3:?new build directory}
case "$arch" in
  arm64) triplet=aarch64-apple-darwin; ffarch=aarch64; x264flags=(); fflags=() ;;
  x86_64) triplet=x86_64-apple-darwin; ffarch=x86_64; x264flags=(--disable-asm); fflags=(--disable-x86asm) ;;
  *) exit 2 ;;
esac
[[ "$(shasum -a 256 < "$src/ffmpeg-8.1.3.tar.xz")" == "7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3  -" ]]
[[ "$(shasum -a 256 < "$src/x264.tar.gz")" == "cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9  -" ]]
mkdir -p "$work"/{x264,ffmpeg,prefix,bin}
tar -xf "$src/x264.tar.gz" -C "$work/x264" --strip-components 1
tar -xf "$src/ffmpeg-8.1.3.tar.xz" -C "$work/ffmpeg" --strip-components 1
export MACOSX_DEPLOYMENT_TARGET=14.0
flags="-arch $arch -mmacosx-version-min=14.0 -ffile-prefix-map=$work=."
export CC=clang
export PKG_CONFIG_LIBDIR="$work/prefix/lib/pkgconfig"
unset PKG_CONFIG_PATH
cd "$work/x264"
./configure --prefix="$work/prefix" --host="$triplet" --enable-static --disable-cli --disable-opencl \
    --extra-cflags="$flags" --extra-ldflags="-arch $arch" "${x264flags[@]}"
make -j"${JOBS:-6}" install-lib-static
cd "$work/ffmpeg"
./configure --prefix=/usr --arch="$ffarch" --target-os=darwin --enable-cross-compile --cc=clang \
    --disable-autodetect --disable-debug --disable-doc --disable-ffplay --disable-indevs --disable-outdevs \
    --enable-static --disable-shared --enable-gpl --enable-libx264 --enable-zlib --enable-bzlib \
    --enable-audiotoolbox --enable-videotoolbox --enable-securetransport \
    --extra-cflags="$flags" --extra-ldflags="-arch $arch" --pkg-config-flags=--static "${fflags[@]}"
make -j"${JOBS:-6}" ffmpeg ffprobe
install -m 755 ffmpeg ffprobe "$work/bin/"
