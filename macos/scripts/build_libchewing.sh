#!/bin/bash
# Build libchewing.dylib for the macOS port of PIME.
#
# The libchewing submodule is pinned to the same C source (v0.5.1-108) that
# the Windows chewing.dll is built from, so the data files shipped in
# python/libchewing/data and existing user phrase databases stay compatible.
# The fixes in macos/patches/libchewing are applied to a copy of the sources,
# so the submodule itself stays the same as for the Windows build.
#
# This script calls clang directly so that only the Xcode Command Line Tools
# are needed (no cmake/autotools).
#
# Output: <out_dir>/libchewing.dylib
#
# Usage: build_libchewing.sh [out_dir]
#
# Written with assistance from Claude Code (Claude Opus 5.5).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_DIR/libchewing"
OUT="${1:-$REPO_DIR/macos/build/libchewing}"
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"
OBJ="$OUT/obj"
PATCHED="$OUT/source"

MACOS_MIN="${MACOS_MIN:-26.0}"
ARCH="${ARCH:-arm64}"

if [ ! -f "$SRC/src/chewingio.c" ]; then
    echo "libchewing submodule is missing. Run: git submodule update --init libchewing" >&2
    exit 1
fi

rm -rf "$OBJ" "$PATCHED"
mkdir -p "$OBJ" "$OUT/include" "$PATCHED"

cp -R "$SRC/include" "$SRC/src" "$PATCHED/"
for p in "$SCRIPT_DIR/../patches/libchewing"/*.patch; do
    patch -s -N -p1 -d "$PATCHED" -i "$p"
done

# Equivalent of cmake/config.h.in for macOS.
cat > "$OUT/include/config.h" <<'EOF'
#define HAVE_SYS_TYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STRTOK_R 1
#define HAVE_ASPRINTF 1
#define HAVE_UNISTD_H 1
#define WITH_SQLITE3 1
#define HAVE_MALLOC 1
EOF

CFLAGS=(
    -arch "$ARCH"
    -mmacosx-version-min="$MACOS_MIN"
    -std=gnu99 -O2 -g -Wall -fPIC -fvisibility=hidden
    -Wno-unused-but-set-variable -Wno-deprecated-non-prototype
    -DUNDER_POSIX -DPIC -D_GNU_SOURCE -DHAVE_CONFIG_H=1
    # Only used as a last-resort search path; PIME always passes its own.
    -DCHEWING_DATADIR="\"/usr/local/share/libchewing\""
    -I"$OUT/include"
    -I"$PATCHED/include"
    -I"$PATCHED/include/internal"
    -I"$PATCHED/src"
    -I"$PATCHED/src/porting_layer/include"
)

LIB_SRCS=(
    src/compat.c
    src/chewingio.c
    src/chewingutil.c
    src/choice.c
    src/dict.c
    src/mod_aux.c
    src/pinyin.c
    src/porting_layer/src/plat_mmap_posix.c
    src/porting_layer/src/plat_path.c
    src/porting_layer/src/rpl_malloc.c
    src/tree.c
    src/userphrase.c
    src/bopomofo.c
    src/chewing-sql.c
    src/userphrase-sql.c
    src/common/chewing-utf8-util.c
    src/common/key2pho.c
)

objs=()
for f in "${LIB_SRCS[@]}"; do
    o="$OBJ/$(echo "$f" | tr '/' '_').o"
    clang "${CFLAGS[@]}" -c "$PATCHED/$f" -o "$o"
    objs+=("$o")
done

# Link the system sqlite3, which always ships with macOS.
clang -arch "$ARCH" -mmacosx-version-min="$MACOS_MIN" -dynamiclib \
    -install_name "@loader_path/libchewing.dylib" \
    -compatibility_version 4.0.0 -current_version 4.1.0 \
    -o "$OUT/libchewing.dylib" "${objs[@]}" -lsqlite3

echo "Built $OUT/libchewing.dylib"
