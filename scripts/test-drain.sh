#!/bin/sh
# Tests the emulated ring's sends against scripted socket results
# (fixtures/ring_send.c), then builds and tests mailbox and direct drain
# publishers on the two Unix loops.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
mkdir -p "$root/build"
"${CC:-gcc}" -O2 -Wall -Wextra -Wno-unused-parameter \
    "$root/scripts/fixtures/ring_send.c" -o "$root/build/ring-send"
"$root/build/ring-send"
"$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/drain-turns" \
    "$root/scripts/fixtures/drain_turns.goose"
python3 "$root/scripts/test-drain-turns.py" "$root/build/drain-turns"
if [ "$(uname -s)" = Linux ]; then
    "$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/drain" "$root/examples/drain.goose"
    python3 "$root/scripts/test-drain.py" "$root/build/drain"
fi
