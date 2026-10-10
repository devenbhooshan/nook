#!/bin/bash
# Runs the test suite. With full Xcode, `swift test` alone works; with only the Command Line Tools,
# the Swift Testing framework lives outside the default search paths, so add them here.
#
# The performance budgets run on their own after everything else, in a release build: suites run in parallel,
# and timings taken while other tests hammer the disk, or in a debug build, aren't meaningful.
# Pass arguments (for example `--filter Sync`) to run just those tests in one go.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libs="$developer_dir/Library/Developer/usr/lib"
    flags=(
        -Xswiftc -F -Xswiftc "$frameworks"
        -Xlinker -F -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$libs"
    )
fi

if [[ $# -gt 0 ]]; then
    exec swift test ${flags[@]+"${flags[@]}"} "$@"
fi
swift test ${flags[@]+"${flags[@]}"} --skip Performance
# Budgets are about what people run, so measure a release build. (-enable-testing keeps @testable imports working.)
swift test -c release -Xswiftc -enable-testing ${flags[@]+"${flags[@]}"} --filter Performance
