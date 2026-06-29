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
echo " Terminal-Bench 2.0  →  ${MODEL_STRING}  (via ${OLLAMA_API_BASE})"
echo " dataset=${DATASET}  agent=${AGENT}  env=${ENV_TYPE}"
echo " tasks=${N_TASKS:-ALL}  concurrent=${N_CONCURRENT}  attempts=${N_ATTEMPTS}"
echo " job=${JOB_NAME}"
echo "════════════════════════════════════════════════════════════════════════"
printf '+ '; printf '%q ' "${CMD[@]}"; echo; echo

"${CMD[@]}"

echo
echo "Done. Results: ${JOBS_DIR}/${JOB_NAME}"
echo "Summary:  python3 summarize_results.py \"${JOBS_DIR}/${JOB_NAME}\""
