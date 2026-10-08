#!/bin/bash
# Run the unit tests of the macOS front end.
#
# With only the Command Line Tools installed (no Xcode), SwiftPM does not
# find the Swift Testing framework by itself, so pass its location.
#
# Written with assistance from Claude Code (Claude Opus 5.5).

set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
LIBS="$DEV_DIR/Library/Developer/usr/lib"

if [ -d "$FRAMEWORKS/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xlinker -F -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$LIBS" \
        "$@"
fi
exec swift test "$@"
