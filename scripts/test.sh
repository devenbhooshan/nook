#!/bin/bash
# Runs the test suite. With full Xcode, `swift test` alone works; with only the Command Line Tools,
# the Swift Testing framework lives outside the default search paths, so add them here.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libs="$developer_dir/Library/Developer/usr/lib"
    exec swift test \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$libs" \
        "$@"
fi
exec swift test "$@"
