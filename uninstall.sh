#!/usr/bin/env bash
# uninstall.sh — Remove BlockADB from macOS.
#
# Usage:
#   sudo ./uninstall.sh

set -euo pipefail

BINARY_PATH="/usr/local/bin/BlockADB"
DAEMON_PLIST_PATH="/Library/LaunchDaemons/com.blockADB.plist"
DAEMON_LABEL="com.blockADB"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: Uninstallation requires root.  Run: sudo $0" >&2
    exit 1
fi

# Unload daemon if installed
if [[ -f "${DAEMON_PLIST_PATH}" ]]; then
    echo "==> Unloading LaunchDaemon…"
    launchctl unload "${DAEMON_PLIST_PATH}" 2>/dev/null || true
    rm -f "${DAEMON_PLIST_PATH}"
    echo "    Removed: ${DAEMON_PLIST_PATH}"
fi

# Remove binary
if [[ -f "${BINARY_PATH}" ]]; then
    echo "==> Removing binary…"
    rm -f "${BINARY_PATH}"
    echo "    Removed: ${BINARY_PATH}"
fi

# Flush any remaining pfctl rules
if /sbin/pfctl -a "${DAEMON_LABEL}" -F rules 2>/dev/null; then
    echo "==> Flushed pfctl anchor ${DAEMON_LABEL}"
fi

echo ""
echo "BlockADB uninstallation complete."
