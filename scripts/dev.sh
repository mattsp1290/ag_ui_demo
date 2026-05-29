#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GO_SERVER_ROOT="/Users/punk1290/git/ag-ui-go-server-example"
SERVER_PORT=8000

cleanup() {
  echo ""
  echo "Shutting down..."
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

# Build and start the Go server in the background.
echo "Building Go server..."
(cd "$GO_SERVER_ROOT" && go build -o /tmp/ag-ui-server ./cmd/server) || {
  echo "Go build failed" >&2
  exit 1
}

echo "Starting Go server on port $SERVER_PORT..."
PORT=$SERVER_PORT CORS_ENABLED=true /tmp/ag-ui-server &
SERVER_PID=$!

# Wait for the server to be ready.
echo -n "Waiting for server..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$SERVER_PORT/health" >/dev/null 2>&1 || \
     nc -z localhost "$SERVER_PORT" 2>/dev/null; then
    echo " ready."
    break
  fi
  sleep 0.5
  echo -n "."
  if [ "$i" -eq 30 ]; then
    echo " timed out waiting for server" >&2
    kill "$SERVER_PID" 2>/dev/null || true
    exit 1
  fi
done

# Start Flutter app in the foreground (macOS desktop).
echo "Starting Flutter app..."
cd "$FLUTTER_ROOT"
flutter run -d macos

cleanup
