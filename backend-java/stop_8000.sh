#!/usr/bin/env bash
set -euo pipefail

# Stop the Java backend bound to port 8000 (macOS/Linux)

if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -ti :8000 || true)"
  if [[ -z "$PIDS" ]]; then
    echo "No process is listening on :8000"
    exit 0
  fi
  echo "Stopping: $PIDS"
  kill -15 $PIDS || true
  exit 0
fi

echo "lsof not found; stop manually (kill the java process)."
exit 1
