#!/usr/bin/env bash
# install.sh — Build and install BlockADB on macOS.
#
# Usage:
#   sudo ./install.sh [--no-daemon]
#
# What it does:
#   1. Builds BlockADB with Swift Package Manager (release configuration).
#   2. Copies the binary to /usr/local/bin/BlockADB.
#   3. (Optional) Installs and loads the LaunchDaemon so BlockADB starts at boot.

set -euo pipefail

BINARY_NAME="BlockADB"
INSTALL_DIR="/usr/local/bin"
DAEMON_PLIST="LaunchDaemon/com.blockADB.plist"
DAEMON_INSTALL_DIR="/Library/LaunchDaemons"
DAEMON_LABEL="com.blockADB"

INSTALL_DAEMON=true

for arg in "$@"; do
    case "$arg" in
        --no-daemon) INSTALL_DAEMON=false ;;
        --help|-h)
            echo "Usage: sudo $0 [--no-daemon]"
            echo ""
            echo "  --no-daemon   Install the binary only; skip LaunchDaemon setup."
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
echo "==> Building BlockADB (release)…"
# ---------------------------------------------------------------------------
swift build -c release --product "${BINARY_NAME}"
BUILT_BINARY=".build/release/${BINARY_NAME}"

if [[ ! -f "${BUILT_BINARY}" ]]; then
    echo "ERROR: Build succeeded but binary not found at ${BUILT_BINARY}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
echo "==> Installing binary to ${INSTALL_DIR}/${BINARY_NAME}…"
# ---------------------------------------------------------------------------
mkdir -p "${INSTALL_DIR}"
cp -f "${BUILT_BINARY}" "${INSTALL_DIR}/${BINARY_NAME}"
chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"

echo "    Installed: $(file "${INSTALL_DIR}/${BINARY_NAME}")"

# ---------------------------------------------------------------------------
if $INSTALL_DAEMON; then
echo "==> Installing LaunchDaemon…"
# ---------------------------------------------------------------------------
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: LaunchDaemon installation requires root.  Run: sudo $0" >&2
        exit 1
    fi

    cp -f "${DAEMON_PLIST}" "${DAEMON_INSTALL_DIR}/com.blockADB.plist"
    chown root:wheel "${DAEMON_INSTALL_DIR}/com.blockADB.plist"
    chmod 644 "${DAEMON_INSTALL_DIR}/com.blockADB.plist"

    # Unload any previously loaded instance before reloading.
    launchctl unload "${DAEMON_INSTALL_DIR}/com.blockADB.plist" 2>/dev/null || true
    launchctl load -w "${DAEMON_INSTALL_DIR}/com.blockADB.plist"

    echo "    LaunchDaemon loaded: ${DAEMON_LABEL}"
    echo "    Status: $(launchctl list | grep "${DAEMON_LABEL}" || echo "not listed yet")"
fi

echo ""
echo "BlockADB installation complete."
echo "Run 'log stream --predicate \"subsystem == \\\"com.blockADB\\\"\"' to monitor activity."
