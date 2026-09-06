#!/bin/sh
# kvm-display-sync installer: builds from source and runs the interactive setup wizard.
#
#   curl -fsSL https://raw.githubusercontent.com/AtakanMavzer/kvm-display-sync/main/install.sh | sh
#
# or, from a clone:  ./install.sh
set -eu

REPO="https://github.com/AtakanMavzer/kvm-display-sync.git"
SRC="${KVM_DISPLAY_SYNC_SRC:-$HOME/.local/src/kvm-display-sync}"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "kvm-display-sync only runs on macOS." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
    echo "Swift toolchain not found. Install the Xcode Command Line Tools first:" >&2
    echo "    xcode-select --install" >&2
    echo "then run this installer again." >&2
    exit 1
fi

# Running from a checkout? Build in place. Otherwise clone (or update) into $SRC.
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/Package.swift" ]; then
    SRC="$here"
elif [ -d "$SRC/.git" ]; then
    echo "Updating $SRC"
    git -C "$SRC" pull -q --ff-only
else
    echo "Cloning into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone -q "$REPO" "$SRC"
fi

echo "Building (release)..."
(cd "$SRC" && swift build -c release 2>&1 | grep -E 'error|Compiling|Build' || true)
BIN="$SRC/.build/release/kvm-display-sync"
[ -x "$BIN" ] || { echo "Build failed." >&2; exit 1; }

# The wizard needs a terminal even when this script is piped from curl.
if [ -t 0 ] || ! ( : < /dev/tty ) 2>/dev/null; then
    exec "$BIN" setup
else
    exec "$BIN" setup < /dev/tty
fi
