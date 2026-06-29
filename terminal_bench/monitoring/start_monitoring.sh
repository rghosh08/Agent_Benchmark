#!/usr/bin/env bash
# Start the Terminal-Bench observability stack:
#   - exporter.py on :9101 (host process; parses jobs dir + GPU + Ollama)
#   - Prometheus on :9090  (docker, host network)
#   - Grafana on :3000     (docker, host network; dashboard auto-provisioned)
set -euo pipefail
cd "$(dirname "$0")"
source ../config.env 2>/dev/null || true
export JOBS_DIR="${JOBS_DIR:-$(cd .. && pwd)/jobs}"
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://localhost:11434}"

# 1. exporter (host process) -------------------------------------------------
if curl -sf http://localhost:9101/metrics >/dev/null 2>&1; then
  echo "exporter already running on :9101"
else
  nohup python3 exporter.py > exporter.log 2>&1 &
  echo $! > exporter.pid
  sleep 1
  echo "exporter started (pid $(cat exporter.pid)) -> exporter.log"
fi

# 2. prometheus + grafana (docker) ------------------------------------------
DC="docker compose"
$DC version >/dev/null 2>&1 || DC="docker-compose"
sg docker -c "$DC up -d" 2>&1 | tail -5 || $DC up -d

echo
echo "─────────────────────────────────────────────────────────"
echo " Grafana:    http://localhost:3000   (admin / admin, or anonymous view)"
echo " Dashboard:  'Terminal-Bench 2.0 — Run Tracker'"
echo " Prometheus: http://localhost:9090"
echo " Exporter:   http://localhost:9101/metrics"
echo "─────────────────────────────────────────────────────────"
