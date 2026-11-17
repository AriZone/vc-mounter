#!/bin/sh
# SPDX-License-Identifier: ISC
# Copyright (c) 2026 AriZone <github@arizone.eu>
#
# Stress test for parallel mounting.
#
# Mounts four throwaway VeraCrypt containers (on loop devices) in parallel,
# over and over, and checks after every round that
#   - every volume is decrypted exactly once (never twice), and
#   - veracrypt itself still tracks every one of them.
# No real disk is touched. Everything is removed again at the end.
# It refuses to start while any VeraCrypt volume is mounted, because its
# cleanup removes every VeraCrypt tracking mount it finds.
#
#   sudo tests/stress-parallel.sh [rounds]              (default: 20 rounds)
#   sudo HELPER=/path/to/vc-mounter-helper tests/stress-parallel.sh 10
set -u

ROUNDS=${1:-20}
COUNT=4
HELPER=${HELPER:-/usr/libexec/vc-mounter/vc-mounter-helper}
PASSWORD=stress-test-password-not-secret
PIM=1

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi
for tool in veracrypt losetup dmsetup findmnt; do
    command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }
done
[ -x "$HELPER" ] || { echo "Helper not found: $HELPER" >&2; exit 1; }

tracking_mounts() {
    findmnt -rn -t fuse.veracrypt -o TARGET
}

if [ -n "$(tracking_mounts)" ] || dmsetup ls | grep -q '^veracrypt'; then
    echo "VeraCrypt volumes (or leftovers of them) are present:" >&2
    tracking_mounts >&2
    dmsetup ls | grep '^veracrypt' >&2
    echo "Dismount everything first, then run this test again." >&2
    exit 1
fi

WORK=$(mktemp -d /tmp/vc-stress.XXXXXX)
LOOPS=""

# Take down whatever is left of our test volumes, without relying on the
# helper under test: decrypted devices on our loop devices first, then
# every VeraCrypt tracking mount (safe: nothing else was mounted at start).
kernel_cleanup() {
    for loop in $LOOPS; do
        for holder in /sys/class/block/"$(basename "$loop")"/holders/*; do
            [ -e "$holder" ] || continue
            name=$(cat "$holder/dm/name")
            findmnt -rn -o TARGET -S "/dev/mapper/$name" | while read -r mp; do
                umount "$mp"
            done
            dmsetup remove "$name"
        done
    done
    # Stacked tracking mounts need one pass per layer.
    for pass in 1 2 3 4; do
        [ -n "$(tracking_mounts)" ] || break
        tracking_mounts | while read -r mp; do
            umount "$mp"
        done
    done
}

finish() {
    "$HELPER" dismount $LOOPS >/dev/null 2>&1
    kernel_cleanup >/dev/null 2>&1
    for loop in $LOOPS; do
        losetup -d "$loop" 2>/dev/null
    done
    exec 3>&- 2>/dev/null
    rm -rf "$WORK"
}
trap finish EXIT
trap 'exit 130' INT TERM

echo "Creating $COUNT test containers in $WORK ..."
i=1
while [ "$i" -le "$COUNT" ]; do
    veracrypt --text --non-interactive --create "$WORK/c$i.hc" --size=5M \
        --volume-type=normal --encryption=AES --hash=sha-512 \
        --filesystem=FAT --password="$PASSWORD" --pim="$PIM" --keyfiles= \
        --random-source=/dev/urandom >/dev/null || exit 1
    loop=$(losetup --find --show "$WORK/c$i.hc") || exit 1
    LOOPS="$LOOPS $loop"
    i=$((i + 1))
done
echo "Loop devices:$LOOPS"
echo "Helper: $HELPER"

# The helper treats end-of-input as "GUI gone, stop". A FIFO held open
# read-write gives it the three credential lines without ever ending.
mkfifo "$WORK/stdin"
exec 3<>"$WORK/stdin"

failed=0
dismount_failures=0
round=1
while [ "$round" -le "$ROUNDS" ]; do
    printf '%s\n%s\n\n' "$PASSWORD" "$PIM" >&3
    results=$("$HELPER" mount $LOOPS <&3 2>&1)
    ok=$(printf '%s\n' "$results" | grep -c "	OK	")

    listing=$(veracrypt --text --non-interactive --list 2>/dev/null)
    problems=""
    for loop in $LOOPS; do
        mapped=$(ls /sys/class/block/"$(basename "$loop")"/holders | wc -l)
        tracked=$(printf '%s\n' "$listing" | grep -c " $loop ")
        [ "$mapped" -eq 1 ] || problems="$problems $loop:decrypted-${mapped}x"
        [ "$tracked" -eq 1 ] || problems="$problems $loop:tracked-${tracked}x"
    done

    if [ "$ok" -eq "$COUNT" ] && [ -z "$problems" ]; then
        echo "round $round: PASS"
    else
        failed=$((failed + 1))
        echo "round $round: FAIL  (helper reported $ok/$COUNT OK)$problems"
        printf '%s\n' "$results" | sed 's/^/    /'
    fi

    # The helper's own dismount is part of the test: note what it leaves.
    "$HELPER" dismount $LOOPS >/dev/null 2>&1
    stale=$(tracking_mounts | wc -l)
    for loop in $LOOPS; do
        stale=$((stale + $(ls /sys/class/block/"$(basename "$loop")"/holders | wc -l)))
    done
    if [ "$stale" -ne 0 ]; then
        echo "round $round: helper dismount left $stale leftover(s) behind"
        dismount_failures=$((dismount_failures + 1))
    fi
    kernel_cleanup >/dev/null 2>&1
    left=$(tracking_mounts | wc -l)
    for loop in $LOOPS; do
        left=$((left + $(ls /sys/class/block/"$(basename "$loop")"/holders | wc -l)))
    done
    if [ "$left" -ne 0 ]; then
        echo "round $round: could not clean up, stopping"
        exit 1
    fi
    round=$((round + 1))
done

echo
if [ "$failed" -eq 0 ] && [ "$dismount_failures" -eq 0 ]; then
    echo "RESULT: all $ROUNDS rounds passed"
else
    echo "RESULT: $failed of $ROUNDS mount rounds FAILED," \
         "$dismount_failures dismount(s) left something behind"
    exit 1
fi
