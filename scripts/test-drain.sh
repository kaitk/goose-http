#!/bin/sh
# Builds and tests mailbox and direct drain publishers on the two Unix loops,
# send_shared on each, and on Linux the uring_send fixture, which needs
# io_uring, and ring_shared, the rings' gathered sends, on io_uring where
# it can.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
"$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/drain-turns" \
    "$root/scripts/fixtures/drain_turns.goose"
python3 "$root/scripts/test-drain-turns.py" "$root/build/drain-turns"
"$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/shared-send" \
    "$root/scripts/fixtures/shared_send.goose"
python3 "$root/scripts/test-shared-send.py" "$root/build/shared-send"
if [ "$(uname -s)" = Linux ]; then
    "$GOOSE" build --cc "${CC:-gcc}" --standalone -o "$root/build/drain" "$root/examples/drain.goose"
    python3 "$root/scripts/test-drain.py" "$root/build/drain"
    # shim/shared.c's goose.h is the fixtures' stand-in.
    "${CC:-gcc}" -Wall -Werror -I "$root/scripts/fixtures" -o "$root/build/uring-send" \
        "$root/scripts/fixtures/uring_send.c" "$root/shim/ring_epoll.c" "$root/shim/net.c" \
        "$root/shim/mail.c" "$root/shim/shared.c" -luring -lpthread
    "$root/build/uring-send"
    "${CC:-gcc}" -Wall -Werror -I "$root/scripts/fixtures" -o "$root/build/ring-shared" \
        "$root/scripts/fixtures/ring_shared.c" "$root/shim/uring.c" "$root/shim/ring_epoll.c" \
        "$root/shim/net.c" "$root/shim/mail.c" "$root/shim/shared.c" -luring -lpthread
    "$root/build/ring-shared"
fi
