#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Run Terminal-Bench 2.0 against a local Ollama model via the Harbor harness.
#
#   ./run_benchmark.sh            # uses config.env
#   N_TASKS=1 ./run_benchmark.sh  # override any config var inline
#   ./run_benchmark.sh -i hello-world   # pass extra raw flags straight to harbor
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env
PATH="$HOME/.local/bin:$PATH"

# ── Architecture guard ───────────────────────────────────────────────────────
# TB2 task/verifier images are published amd64-only. On a non-x86_64 host they
# run under QEMU emulation, where the verifier's Python/pytest+numpy segfaults
# (signal 11) *after* the agent phase has already burned real API tokens — every
# task then scores a false 0.0. Refuse to start unless we're on native amd64.
# Override with ALLOW_EMULATED_ARCH=1 if you really want an (unscoreable) run.
if [ "${ALLOW_EMULATED_ARCH:-0}" != "1" ]; then
  host_arch="$(uname -m)"
  docker_arch="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || true)"
  if [ "$host_arch" != "x86_64" ] || { [ -n "$docker_arch" ] && [ "$docker_arch" != "amd64" ]; }; then
    printf '\033[31m✗ Architecture mismatch — refusing to run.\033[0m\n' >&2
    printf '  host uname -m   : %s\n' "$host_arch" >&2
    printf '  docker server   : %s\n' "${docker_arch:-unknown}" >&2
    printf '  TB2 task images are amd64-only; on this host they run under QEMU\n' >&2
    printf '  emulation and the verifier (pytest/numpy) segfaults, producing\n' >&2
    printf '  false 0.0 scores while still spending API tokens.\n' >&2
    printf '  → Run this benchmark on a native x86_64 host.\n' >&2
    printf '  → To force an (unscoreable) emulated run anyway: ALLOW_EMULATED_ARCH=1 %s\n' "$0" >&2
    exit 1
  fi
fi

JOB_NAME="gemma4-31b-$(date +%Y%m%d-%H%M%S)"

# Assemble the harbor command -------------------------------------------------
CMD=( harbor run
  --dataset       "$DATASET"
  --agent         "$AGENT"
  --model         "$MODEL_STRING"
  --env           "$ENV_TYPE"
  --n-concurrent  "$N_CONCURRENT"
  --n-attempts    "$N_ATTEMPTS"
  --timeout-multiplier "$TIMEOUT_MULTIPLIER"
  --jobs-dir      "$JOBS_DIR"
  --job-name      "$JOB_NAME"
  --yes                                  # auto-confirm host-access prompt
)

# Optional task-count limit (omit to run the full 89-task suite)
if [ -n "${N_TASKS:-}" ] && [ "${N_TASKS}" != "0" ]; then
  CMD+=( --n-tasks "$N_TASKS" )
fi
# Optional task-name filter
if [ -n "${INCLUDE_GLOB:-}" ]; then
  CMD+=( --include-task-name "$INCLUDE_GLOB" )
fi
# Anything passed on the command line is appended verbatim to harbor
CMD+=( "$@" )

echo "════════════════════════════════════════════════════════════════════════"
echo " Terminal-Bench 2.0  →  ${MODEL_STRING}  (via Anthropic API)"
echo " dataset=${DATASET}  agent=${AGENT}  env=${ENV_TYPE}"
echo " tasks=${N_TASKS:-ALL}  concurrent=${N_CONCURRENT}  attempts=${N_ATTEMPTS}"
echo " job=${JOB_NAME}"
echo "════════════════════════════════════════════════════════════════════════"
printf '+ '; printf '%q ' "${CMD[@]}"; echo; echo

"${CMD[@]}"

echo
echo "Done. Results: ${JOBS_DIR}/${JOB_NAME}"
echo "Summary:  python3 summarize_results.py \"${JOBS_DIR}/${JOB_NAME}\""
