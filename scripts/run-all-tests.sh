#!/bin/bash
# Runs the complete test workflow: installs munkitools, builds and installs
# the plugin package system-wide, starts Azurite and runs the end-to-end tests.
# Requires sudo (installs to /usr/local/munki).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

AZURITE_PID=""
cleanup() {
    if [ -n "$AZURITE_PID" ]; then
        kill "$AZURITE_PID" 2>/dev/null || true
        wait "$AZURITE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

section "Unit tests"
(cd "$PROJECT_ROOT" && swift test)

section "Installing munkitools"
"$SCRIPT_DIR/install-munkitools.sh" --install

if ! command -v az &> /dev/null; then
    section "Installing Azure CLI"
    brew install azure-cli
fi

section "Building plugin package"
"$SCRIPT_DIR/build-plugin-package.sh"

section "Installing plugin package"
sudo installer -pkg "$PROJECT_ROOT"/build/AzureBlobRepoPlugin-*.pkg -target /

section "Starting Azurite"
AZURITE_PID=$("$SCRIPT_DIR/start-azurite.sh")

section "End-to-end tests"
"$SCRIPT_DIR/test-e2e.sh"
