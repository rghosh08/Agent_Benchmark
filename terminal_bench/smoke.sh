#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Single-task smoke test.
#
# Runs one trivial task (`hello-world` by default) end-to-end to confirm the
# whole pipeline is healthy: agent → task container → verifier → score. It's the
# cheapest way to prove a host is good — especially after moving to a new box.
#
# A REAL pass here means the verifier ran natively (no QEMU segfault) and can
# score tasks. If this scores 0.0, do NOT kick off the full suite — debug first.
#
#   ./smoke.sh                       # runs hello-world
#   SMOKE_TASK='fix-*' ./smoke.sh    # pick a different task glob
#   ./smoke.sh --some-harbor-flag    # extra flags pass through to harbor
#
# This just delegates to run_benchmark.sh with a 1-task override, so it inherits
# the architecture guard and everything in config.env.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

echo "── Smoke test: single task '${SMOKE_TASK:-hello-world}' ──"
exec env N_TASKS=1 INCLUDE_GLOB="${SMOKE_TASK:-hello-world}" ./run_benchmark.sh "$@"
