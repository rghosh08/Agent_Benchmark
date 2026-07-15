# Terminal-Bench 2.0 — Anthropic Claude Haiku **or** local Ollama

Benchmark a model on [Terminal-Bench 2.0](https://www.tbench.ai/benchmarks/terminal-bench-2)
— 89 real terminal tasks (ML, sysadmin, security, scientific computing, SWE) graded
by per-task verifiers inside Docker containers.

The official harness is **[Harbor](https://github.com/harbor-framework/terminal-bench-2)**.
Harbor runs the `terminus-2` agent on the host; the agent drives a task container over
tmux and calls your model through LiteLLM. This setup supports **two interchangeable
backends** — pick one in `config.env`:

```
                                  ┌─ anthropic/claude-haiku-4-5   (Anthropic API)   ← default
  Harbor (host) ──LiteLLM──▶ model┤
        │                         └─ ollama_chat/gemma4:31b       (localhost:11434)
        └──tmux──▶  task container (Docker)  ──▶  verifier → pass/fail
```

## Files
| File | Purpose |
|------|---------|
| `config.env`            | All knobs: **backend/model**, dataset, task count, concurrency, timeouts |
| `preflight.sh`          | Checks docker / harbor / API key (or ollama) before a run |
| `run_benchmark.sh`      | Builds & runs the `harbor run …` command |
| `summarize_results.py`  | Parses the job output into a pass-rate table |

## Choosing a backend

The backend is selected entirely by `MODEL_STRING` (and the matching credentials) in
`config.env`. Swap the block you want.

### A) Anthropic Claude Haiku — **current default**
```bash
ANTHROPIC_MODEL="claude-haiku-4-5-20251001"   # Claude Haiku 4.5
MODEL_STRING="anthropic/${ANTHROPIC_MODEL}"

# Key is read from the shell env, falling back to ~/.bashrc:
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  ANTHROPIC_API_KEY="$(bash -lc 'source ~/.bashrc 2>/dev/null; printf %s "${ANTHROPIC_API_KEY:-}"')"
fi
export ANTHROPIC_API_KEY
```
LiteLLM reads `ANTHROPIC_API_KEY` from the environment. No local server needed — it's a
hosted API, so you can raise `N_CONCURRENT` (mind Anthropic rate limits and cost).

### B) Local Ollama (e.g. `gemma4:31b`)
```bash
OLLAMA_MODEL="gemma4:31b-ctx32k"              # custom build: 32K ctx for faster prefill
MODEL_STRING="ollama_chat/${OLLAMA_MODEL}"
export OLLAMA_API_BASE="http://localhost:11434"
```
LiteLLM reads `OLLAMA_API_BASE` from the environment.

**OpenAI-compatible alternative** (some agents prefer it):
```bash
MODEL_STRING="openai/gemma4:31b"
export OPENAI_API_BASE="http://localhost:11434/v1"
export OPENAI_API_KEY="ollama"                # any non-empty string
```

## Prerequisites (one-time)

1. **uv + Harbor**:
   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   uv tool install harbor
   ```
2. **Docker access** — Harbor builds task containers:
   ```bash
   sudo usermod -aG docker $USER && newgrp docker   # then re-login
   docker ps                                        # must succeed
   ```
3. **Backend credentials:**
   - **Haiku:** `export ANTHROPIC_API_KEY="sk-ant-..."` (or keep it in `~/.bashrc` — `config.env` picks it up).
   - **Ollama:** `ollama serve` and `ollama pull gemma4:31b`.

## Run

```bash
cd ~/Agent_Benchmark/terminal_bench
./preflight.sh            # verify the environment for the selected backend
./run_benchmark.sh        # runs 5 tasks by default (see config.env)
```

`preflight.sh` adapts to the backend: for Haiku it checks the API key and does a live
Messages-API smoke test; for Ollama it checks the server and pulls a completion.

Scale up by editing `config.env` (or overriding inline):

```bash
N_TASKS=0 N_CONCURRENT=4 ./run_benchmark.sh        # full 89-task suite
INCLUDE_GLOB='hello-world' ./run_benchmark.sh      # a single named task
./run_benchmark.sh -i 'fix-*'                      # extra flags pass through to harbor
```

## Results

```bash
python3 summarize_results.py            # newest job under ./jobs
python3 summarize_results.py jobs/<job-name>
```

Compare against the public [TB2 leaderboard](https://www.tbench.ai/leaderboard/terminal-bench/2.0).

## Notes & gotchas

- **Haiku (hosted API).** No local server; `N_CONCURRENT` can go higher, bounded by
  Anthropic rate limits and cost rather than VRAM. Each task is a full agentic rollout,
  so token usage adds up — start with `N_TASKS=5`.
- **Ollama (local).** A 31B local model is slow on long agentic rollouts. Start with
  `N_TASKS=5` and low `N_CONCURRENT`; bump `TIMEOUT_MULTIPLIER` to give the agent room.
  Concurrency serializes on one Ollama instance (generation is not parallelized).
- **Context window (Ollama).** Agentic tasks need a large context. If you see truncation,
  bake a bigger `num_ctx` into a custom Modelfile (see `Modelfile.gemma4-ctx32k`).
- **First run is slow** — Harbor downloads the dataset and builds task Docker images once.
- **Dataset id.** If `terminal-bench@2.0` doesn't resolve, try
  `-d terminal-bench/terminal-bench-2`, or `harbor datasets list`.
- **Networking.** The agent runs on the host. For Ollama, `localhost:11434` is reachable;
  if you sandbox the agent's network, allow it with `--allow-agent-host localhost`.
</content>
</invoke>
