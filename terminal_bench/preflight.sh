#!/usr/bin/env bash
# Pre-flight checks: verify everything Harbor needs before a TB2 run.
set -uo pipefail
cd "$(dirname "$0")"
source ./config.env

PATH="$HOME/.local/bin:$PATH"
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=1; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
FAIL=0

echo "Terminal-Bench 2.0 pre-flight"
echo

echo "[1] Tooling"
command -v uv     >/dev/null && ok "uv installed ($(uv --version))"        || bad "uv missing — curl -LsSf https://astral.sh/uv/install.sh | sh"
command -v harbor >/dev/null && ok "harbor installed ($(harbor --version 2>&1 | head -1))" || bad "harbor missing — uv tool install harbor"

echo "[2] Docker (Harbor needs to build/run task containers)"
if docker ps >/dev/null 2>&1; then
  ok "docker reachable"
else
  bad "cannot talk to docker daemon"
  warn "fix: sudo usermod -aG docker \$USER && newgrp docker   (then re-login)"
fi

echo "[3] Ollama"
if curl -sf "${OLLAMA_API_BASE}/api/version" >/dev/null; then
  ok "ollama up at ${OLLAMA_API_BASE} ($(curl -s ${OLLAMA_API_BASE}/api/version))"
else
  bad "ollama not responding at ${OLLAMA_API_BASE} — run: ollama serve"
fi
if curl -sf "${OLLAMA_API_BASE}/api/tags" 2>/dev/null | grep -q "\"${OLLAMA_MODEL}\""; then
  ok "model present: ${OLLAMA_MODEL}"
else
  bad "model '${OLLAMA_MODEL}' not pulled — run: ollama pull ${OLLAMA_MODEL}"
fi

echo "[4] Live inference smoke test"
RESP=$(curl -sf "${OLLAMA_API_BASE}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${OLLAMA_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with the word READY\"}],\"max_tokens\":5}" 2>/dev/null)
if echo "$RESP" | grep -qi 'choices'; then ok "model answered an OpenAI-compatible request"; else bad "no valid completion returned"; fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32mAll checks passed — ready to run ./run_benchmark.sh\033[0m\n"
else
  printf "\033[31mSome checks failed — resolve the ✗ items above first.\033[0m\n"; exit 1
fi
