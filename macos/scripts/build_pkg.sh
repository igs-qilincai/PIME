#!/bin/bash
# Build an installer package of PIME.app for distribution.
#
# The package installs PIME.app into ~/Library/Input Methods and runs the
# same steps as install.sh. Unlike PIME.app in a zip or disk image, files
# installed by Installer are not quarantined, so Gatekeeper does not block
# the input method, which is not notarized.
#
# Usage: build_pkg.sh [path/to/PIME.app]
# Output: macos/build/PIME-<version>-arm64.pkg (not signed)
#
# Written with assistance from Claude Code (Claude Opus 5.5).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
BUILD_DIR="$MACOS_DIR/build"
APP_SRC="${1:-$BUILD_DIR/PIME.app}"
IDENTIFIER=org.easyime.inputmethod.PIME

if [ ! -d "$APP_SRC" ]; then
    echo "$APP_SRC not found. Run scripts/build_app.sh first." >&2
    exit 1
fi
codesign --verify --strict "$APP_SRC"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist")"
RELEASE="$(tr -d '[:space:]' < "$REPO_DIR/version.txt")"
PKG="$BUILD_DIR/PIME-$RELEASE-arm64.pkg"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Building the component package"
mkdir -p "$WORK_DIR/root"
ditto "$APP_SRC" "$WORK_DIR/root/PIME.app"
# Installer moves a "relocatable" bundle to wherever LaunchServices last
# saw the same bundle ID, e.g. macos/build/PIME.app. Always install it in
# the input methods folder instead.
pkgbuild --analyze --root "$WORK_DIR/root" "$WORK_DIR/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK_DIR/component.plist"
pkgbuild --root "$WORK_DIR/root" \
    --component-plist "$WORK_DIR/component.plist" \
    --install-location "/Library/Input Methods" \
    --scripts "$MACOS_DIR/pkg/scripts" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    "$WORK_DIR/PIME-component.pkg"

echo "==> Building $PKG"
# --domains in distribution.xml makes /Library/Input Methods relative to
# the user's home directory.
sed -e "s/@VERSION@/$VERSION/g" -e "s/@COMPONENT@/PIME-component.pkg/g" \
    "$MACOS_DIR/pkg/distribution.xml" > "$WORK_DIR/distribution.xml"
productbuild --distribution "$WORK_DIR/distribution.xml" \
    --resources "$MACOS_DIR/pkg/resources" \
    --package-path "$WORK_DIR" \
    "$PKG"

echo "Built $PKG ($(du -h "$PKG" | cut -f1))"
shasum -a 256 "$PKG"
