#!/usr/bin/env bash
# Stop the observability stack.
set -uo pipefail
cd "$(dirname "$0")"
DC="docker compose"; $DC version >/dev/null 2>&1 || DC="docker-compose"
sg docker -c "$DC down" 2>&1 | tail -5 || $DC down || true
if [ -f exporter.pid ]; then
  kill "$(cat exporter.pid)" 2>/dev/null && echo "exporter stopped" || true
  rm -f exporter.pid
fi
