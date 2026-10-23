#!/bin/sh
# Reproduces the package-only check on Linux; keeps builds under build/.
set -eu
root=$(git rev-parse --show-toplevel)
scratch=$root/build/send-copy-bench
mkdir -p "$scratch" "$root/build/bench"
git worktree add --detach "$scratch/before" df12a627c9f4df51465f1ac7c324c17e86dc78b3
git worktree add --detach "$scratch/after" a12328478b48efd9ea6adb2038e3f185fc130651
for variant in before after; do
    (cd "$scratch/$variant" && CC=clang LOOP=uring sh scripts/build.sh)
    cp "$scratch/$variant/build/server" "$root/build/bench/goose-send-$variant"
done
cd "$root"
LOOP=uring RUNS=3 N=10000000 sh bench/count.sh goose-send-before goose-send-after
LOOP=uring RUNS=3 N=10000000 PORT=29291 sh bench/count.sh goose-send-after goose-send-before
