#!/bin/bash
# Build PIME.app, the macOS input method bundle with the chewing backend.
#
# Bundle layout:
#   Contents/MacOS/PIME                InputMethodKit front end (Swift)
#   Contents/Resources/python/         python-build-standalone runtime + tornado
#   Contents/Resources/backend/        PIME python backend, chewing IME only
#   Contents/Resources/version.txt     used by the chewing config tool
#
# Usage: build_app.sh
# Environment:
#   CODESIGN_IDENTITY  signing identity (default "Apple Development";
#                      "-" signs ad hoc)
#
# Written with assistance from Claude Code (Claude Opus 5.5).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
BUILD_DIR="$MACOS_DIR/build"
CACHE_DIR="$BUILD_DIR/cache"
APP="$BUILD_DIR/PIME.app"
RESOURCES="$APP/Contents/Resources"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"

# Pinned Python runtime: https://github.com/astral-sh/python-build-standalone
PYTHON_TAG=20260901
PYTHON_VERSION=3.12.14
PYTHON_ARCHIVE="cpython-${PYTHON_VERSION}+${PYTHON_TAG}-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_TAG}/${PYTHON_ARCHIVE/+/%2B}"
PYTHON_SHA256=3ee3ee547cedfeb7c2b16b2b7156039f7b470bb8f857e226fd3d2eb11db83c76

# Used by the chewing config tool (config_tool.py).
TORNADO_REQUIREMENT="tornado==6.5.9 --hash=sha256:dea3bee433b73d6312d993ce89ad5f2b8d3ed9fde56e79ba5342b9edb78d342a"

echo "==> Building the Swift front end"
(cd "$MACOS_DIR" && swift build -c release --product PIME --arch arm64)
FRONTEND="$(cd "$MACOS_DIR" && swift build -c release --product PIME --arch arm64 --show-bin-path)/PIME"

echo "==> Building libchewing"
"$SCRIPT_DIR/build_libchewing.sh" "$BUILD_DIR/libchewing"

echo "==> Fetching the Python runtime"
mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHE_DIR/$PYTHON_ARCHIVE" ]; then
    curl -fsSL --retry 3 -o "$CACHE_DIR/$PYTHON_ARCHIVE.part" "$PYTHON_URL"
    mv "$CACHE_DIR/$PYTHON_ARCHIVE.part" "$CACHE_DIR/$PYTHON_ARCHIVE"
fi
echo "$PYTHON_SHA256  $CACHE_DIR/$PYTHON_ARCHIVE" | shasum -a 256 -c -

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"
cp "$FRONTEND" "$APP/Contents/MacOS/PIME"
VERSION="$(sed -E 's/[^0-9.].*$//' "$REPO_DIR/version.txt")"
sed "s/@VERSION@/$VERSION/g" "$MACOS_DIR/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp -R "$MACOS_DIR/Resources/en.lproj" "$MACOS_DIR/Resources/zh-Hant.lproj" "$RESOURCES/"
swiftc -O -o "$BUILD_DIR/make_icon" "$SCRIPT_DIR/make_icon.swift"
"$BUILD_DIR/make_icon" "酷" "$RESOURCES/PIME.tiff"
cp "$REPO_DIR/version.txt" "$RESOURCES/version.txt"

# Python runtime (the archive contains a top-level "python" directory)
tar -xzf "$CACHE_DIR/$PYTHON_ARCHIVE" -C "$RESOURCES"
PYTHON="$RESOURCES/python/bin/python3"
REQUIREMENTS="$(mktemp)"
echo "$TORNADO_REQUIREMENT" > "$REQUIREMENTS"
"$PYTHON" -m pip install --quiet --disable-pip-version-check --no-cache-dir \
    --only-binary=:all: --require-hashes -r "$REQUIREMENTS"
rm -f "$REQUIREMENTS"
# Drop parts of the runtime the backend never uses.
PYLIB="$RESOURCES/python/lib/python${PYTHON_VERSION%.*}"
rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/tkinter" "$PYLIB/turtledemo" \
    "$PYLIB/ensurepip" "$PYLIB/lib2to3" "$PYLIB/site-packages/pip" \
    "$PYLIB/site-packages"/pip-*.dist-info \
    "$RESOURCES/python/lib"/tcl* "$RESOURCES/python/lib"/tk* "$RESOURCES/python/lib"/itcl* \
    "$RESOURCES/python/lib"/thread* "$RESOURCES/python/lib"/libtcl* "$RESOURCES/python/lib"/libtk* \
    "$RESOURCES/python/include" "$RESOURCES/python/share"
rm -f "$PYLIB"/lib-dynload/_tkinter*.so "$RESOURCES/python/bin"/idle3* "$RESOURCES/python/bin"/pip*

# Backend: the python/ directory of PIME with only the chewing input method.
BACKEND="$RESOURCES/backend"
mkdir -p "$BACKEND/input_methods" "$BACKEND/libchewing"
cp "$REPO_DIR/python"/{server.py,serviceManager.py,textService.py,keycodes.py} "$BACKEND/"
cp "$REPO_DIR/python/input_methods/__init__.py" "$BACKEND/input_methods/"
rsync -a --exclude __pycache__ "$REPO_DIR/python/input_methods/chewing" "$BACKEND/input_methods/"
cp "$REPO_DIR/python/libchewing"/{__init__.py,libchewing.py} "$BACKEND/libchewing/"
cp -R "$REPO_DIR/python/libchewing/data" "$BACKEND/libchewing/"
cp "$BUILD_DIR/libchewing/libchewing.dylib" "$BACKEND/libchewing/"

# Precompile everything. The bundle is read-only after signing, and
# unchecked-hash .pyc files stay valid regardless of file timestamps.
"$PYTHON" -m compileall -q -j 0 --invalidation-mode unchecked-hash "$PYLIB" "$BACKEND" > /dev/null

echo "==> Signing with \"$CODESIGN_IDENTITY\""
# Nested code outside Contents/MacOS has to be signed on its own first.
find "$RESOURCES" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' file; do
        if file -b "$file" | grep -q '^Mach-O'; then
            codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" "$file"
        fi
    done
codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
