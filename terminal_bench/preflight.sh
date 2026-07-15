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

echo "[2b] Architecture (TB2 task images are amd64-only)"
HOST_ARCH="$(uname -m)"
DOCKER_ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || true)"
if [ "$HOST_ARCH" = "x86_64" ] && { [ -z "$DOCKER_ARCH" ] || [ "$DOCKER_ARCH" = "amd64" ]; }; then
  ok "native amd64 (uname=$HOST_ARCH, docker=${DOCKER_ARCH:-unknown})"
else
  bad "non-amd64 host (uname=$HOST_ARCH, docker=${DOCKER_ARCH:-unknown}) — task images run under QEMU"
  warn "the verifier (pytest/numpy) segfaults under emulation → every task scores a false 0.0"
  warn "fix: run on a native x86_64 host (emulation cannot be scored reliably)"
fi

case "${MODEL_STRING}" in
  anthropic/*)
    echo "[3] Anthropic API key"
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      ok "ANTHROPIC_API_KEY present (len=${#ANTHROPIC_API_KEY})"
    else
      bad "ANTHROPIC_API_KEY not set — export it or add it to ~/.bashrc"
    fi

    echo "[4] Live inference smoke test (${MODEL_STRING})"
    RESP=$(curl -sf "https://api.anthropic.com/v1/messages" \
      -H "x-api-key: ${ANTHROPIC_API_KEY:-}" \
      -H "anthropic-version: 2023-06-01" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${ANTHROPIC_MODEL}\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"reply with the word READY\"}]}" 2>/dev/null)
    if echo "$RESP" | grep -q '"content"'; then ok "model answered a Messages API request"; else bad "no valid completion returned — check key/model. Response: $(echo "$RESP" | head -c 200)"; fi
    ;;

  ollama_chat/*|openai/*)
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

    echo "[4] Live inference smoke test (${MODEL_STRING})"
    RESP=$(curl -sf "${OLLAMA_API_BASE}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${OLLAMA_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with the word READY\"}],\"max_tokens\":5}" 2>/dev/null)
    if echo "$RESP" | grep -qi 'choices'; then ok "model answered an OpenAI-compatible request"; else bad "no valid completion returned"; fi
    ;;

  *)
    bad "unrecognized MODEL_STRING='${MODEL_STRING}' — expected anthropic/*, ollama_chat/*, or openai/*"
    ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32mAll checks passed — ready to run ./run_benchmark.sh\033[0m\n"
else
  printf "\033[31mSome checks failed — resolve the ✗ items above first.\033[0m\n"; exit 1
fi
