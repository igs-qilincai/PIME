#!/bin/bash
# Run the unit tests of the macOS front end, the libchewing patches and the
# chewing backend.
#
# With only the Command Line Tools installed (no Xcode), SwiftPM does not
# find the Swift Testing framework by itself, so pass its location.
#
# Written with assistance from Claude Code (Claude Opus 5.5).

set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build_libchewing.sh >/dev/null
/usr/bin/python3 -I Tests/libchewing/test_userphrase_db.py \
    build/libchewing/libchewing.dylib ../python/libchewing/data
/usr/bin/python3 -I Tests/backend/test_chewing_ime.py ../python

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
