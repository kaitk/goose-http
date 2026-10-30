#!/bin/sh
# Builds and tests mailbox and direct drain publishers on the two Unix loops,
# and on Linux the uring_send fixture, which needs io_uring.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
"$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/drain-turns" \
    "$root/scripts/fixtures/drain_turns.goose"
python3 "$root/scripts/test-drain-turns.py" "$root/build/drain-turns"
"$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/timeout-live" \
    "$root/scripts/fixtures/timeout_live.goose"
python3 "$root/scripts/test-timeout-live.py" "$root/build/timeout-live"
"$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/later-keys" \
    "$root/scripts/fixtures/later_keys.goose"
python3 "$root/scripts/test-later-keys.py" "$root/build/later-keys"
if [ "$(uname -s)" = Linux ]; then
    "$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/drain" "$root/examples/drain.goose"
    python3 "$root/scripts/test-drain.py" "$root/build/drain"
    "${CC:-gcc}" -Wall -Werror -o "$root/build/uring-send" "$root/scripts/fixtures/uring_send.c" \
        "$root/shim/ring_epoll.c" "$root/shim/net.c" "$root/shim/mail.c" -luring -lpthread
    "$root/build/uring-send"
fi
