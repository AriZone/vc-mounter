#!/bin/sh
# SPDX-License-Identifier: ISC
# Copyright (c) 2026 AriZone <github@arizone.eu>
#
# Installs (or removes) the root-side parts of vc-mounter:
#   /usr/libexec/vc-mounter/vc-mounter-helper                 root helper
#   /usr/share/polkit-1/actions/eu.arizone.vcmounter.policy   polkit action
# The GUI (vc-mounter) is not installed anywhere; run it from where it is.
#
#   sudo ./install.sh              install or update
#   sudo ./install.sh --uninstall  remove
set -eu

HELPER_DIR=/usr/libexec/vc-mounter
HELPER=$HELPER_DIR/vc-mounter-helper
POLICY=/usr/share/polkit-1/actions/eu.arizone.vcmounter.policy
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0 $*" >&2
    exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
    rm -f -- "$HELPER" "$POLICY"
    rmdir -- "$HELPER_DIR" 2>/dev/null || true
    echo "Removed $HELPER and $POLICY"
    exit 0
fi

for f in vc-mounter-helper eu.arizone.vcmounter.policy; do
    [ -f "$SRC/$f" ] || { echo "Missing $SRC/$f" >&2; exit 1; }
done

install -d -o root -g root -m 0755 -- "$HELPER_DIR"
install -o root -g root -m 0755 -- "$SRC/vc-mounter-helper" "$HELPER"
install -o root -g root -m 0644 -- "$SRC/eu.arizone.vcmounter.policy" "$POLICY"

echo "Installed:"
ls -l -- "$HELPER" "$POLICY"
