#!/bin/bash
# Speed checks on a mailbox the size of a real one: 120,000 messages over four years, three accounts.
# The first run builds the mailbox (about 30 seconds) and keeps it in build/, so later runs start at once.
# Delete build/bench.sqlite* after changing the schema or the generator, to start fresh.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
NOOK_BENCH=1 NOOK_BENCH_DB="$PWD/build/bench.sqlite" ./scripts/test.sh -c release -Xswiftc -enable-testing --filter SearchBenchmark "$@" 2>&1 \
    | grep -vE "^\[|warning:|^ *\||Compiling|Build"
