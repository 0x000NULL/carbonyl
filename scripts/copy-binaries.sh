#!/usr/bin/env bash

export CARBONYL_ROOT=$(cd $(dirname -- "$0") && dirname -- $(pwd))

cd "$CARBONYL_ROOT"
source "scripts/env.sh"

target="$1"
cpu="$2"

triple=$(scripts/platform-triple.sh "$cpu")
dest="build/pre-built/$triple"
src="$CHROMIUM_SRC/out/$target"

lib_ext="so"
lib_prefix="lib"
bin_ext=""
if [ -f "$src"/libEGL.dylib ]; then
    lib_ext="dylib"
elif [ -f "$src"/libEGL.dll ]; then
    lib_ext="dll"
    lib_prefix=""
    bin_ext=".exe"
fi

rm -rf "$dest"
mkdir -p "$dest"
cd "$dest"

cp "$src/headless_shell$bin_ext" "carbonyl$bin_ext"
cp "$src/icudtl.dat" .
cp "$src/libEGL.$lib_ext" .
cp "$src/libGLESv2.$lib_ext" .
cp "$src"/v8_context_snapshot*.bin .
cp "$CARBONYL_ROOT/build/$triple/release/${lib_prefix}carbonyl.$lib_ext" .

files="carbonyl$bin_ext "

if [ "$lib_ext" == "so" ]; then
    cp "$src/libvk_swiftshader.so" .
    cp "$src/libvulkan.so.1" .
    cp "$src/vk_swiftshader_icd.json" .

    files+=$(echo *.so *.so.1)
fi

if [ "$lib_ext" == "dll" ]; then
    # No GNU strip on Windows; debug symbols live in separate PDB files which
    # are already excluded from $dest.
    :
elif [[ "$cpu" == "arm64" ]] && command -v aarch64-linux-gnu-strip; then
    aarch64-linux-gnu-strip $files
else
    strip $files
fi

echo "Binaries copied to $dest"
