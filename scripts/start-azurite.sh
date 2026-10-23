#!/bin/bash
# Starts the Azurite Blob Storage emulator in the background and prints its PID
# (only the PID goes to stdout so callers can capture it)

set -e

AZURITE_VERSION="3.37.0"
TOOLS_DIR="${TOOLS_DIR:-$HOME/.azureblobrepo-test/tools}"
STORAGE_DIR="${STORAGE_DIR:-$(mktemp -d)}"
PORT="${PORT:-10000}"
LOG_FILE="${LOG_FILE:-/tmp/azurite.log}"

AZURITE_BIN="$TOOLS_DIR/node_modules/.bin/azurite-blob"
if [ ! -x "$AZURITE_BIN" ]; then
    echo "Installing azurite@$AZURITE_VERSION into $TOOLS_DIR..." >&2
    npm install --silent --prefix "$TOOLS_DIR" "azurite@$AZURITE_VERSION" >&2
fi

echo "Starting Azurite on 127.0.0.1:$PORT (storage: $STORAGE_DIR)" >&2
"$AZURITE_BIN" \
    --silent \
    --location "$STORAGE_DIR" \
    --blobHost 127.0.0.1 \
    --blobPort "$PORT" &> "$LOG_FILE" &
AZURITE_PID=$!

for _ in $(seq 1 60); do
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
        echo "✓ Azurite is ready" >&2
        echo "$AZURITE_PID"
        exit 0
    fi
    if ! kill -0 "$AZURITE_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

echo "❌ Error: Azurite did not start" >&2
cat "$LOG_FILE" >&2
kill "$AZURITE_PID" 2>/dev/null || true
exit 1
