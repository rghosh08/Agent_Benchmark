# Terminal-Bench 2.0 × local Ollama (`gemma4:31b`)

Benchmark a **local Ollama model** on [Terminal-Bench 2.0](https://www.tbench.ai/benchmarks/terminal-bench-2)
— 89 real terminal tasks (ML, sysadmin, security, scientific computing, SWE) graded
by per-task verifiers inside Docker containers.

The official harness is **[Harbor](https://github.com/harbor-framework/terminal-bench-2)**.
Harbor runs the `terminus-2` agent on the host; the agent drives a task container over
tmux and calls your model through LiteLLM. We point LiteLLM at Ollama on `localhost:11434`.

```
  Harbor (host)  ──LiteLLM──▶  Ollama  http://localhost:11434  (gemma4:31b)
        │
        └──tmux──▶  task container (Docker)  ──▶  verifier → pass/fail
```

## Files
| File | Purpose |
|------|---------|
| `config.env`            | All knobs: model, dataset, task count, concurrency, timeouts |
| `preflight.sh`          | Checks docker / ollama / harbor / model before a run |
| `run_benchmark.sh`      | Builds & runs the `harbor run …` command |
| `summarize_results.py`  | Parses the job output into a pass-rate table |

## Prerequisites (one-time)

1. **uv + Harbor** (already installed in this setup):
   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   uv tool install harbor
   ```
2. **Docker access** — Harbor builds task containers. The daemon is running but your
   user needs socket access:
   ```bash
   sudo usermod -aG docker $USER && newgrp docker   # then re-login
   docker ps                                        # must succeed
   ```
3. **Ollama serving the model** (already done):
   ```bash
   ollama serve            # if not already running
   ollama pull gemma4:31b
   ```

## Run

```bash
cd ~/terminal_bench
./preflight.sh            # verify the environment
./run_benchmark.sh        # runs 5 tasks by default (see config.env)
```

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

## How the model is wired

`config.env` sets:
```bash
MODEL_STRING="ollama_chat/gemma4:31b"      # LiteLLM provider/model
export OLLAMA_API_BASE="http://localhost:11434"
```
`run_benchmark.sh` passes `--model "$MODEL_STRING"` to Harbor; LiteLLM reads
`OLLAMA_API_BASE` from the environment.

**OpenAI-compatible alternative** (some agents prefer it) — in `config.env`:
```bash
MODEL_STRING="openai/gemma4:31b"
export OPENAI_API_BASE="http://localhost:11434/v1"
export OPENAI_API_KEY="ollama"             # any non-empty string
```

## Notes & gotchas

- **A 31B local model is slow** on long agentic rollouts. Start with `N_TASKS=5` and
  low `N_CONCURRENT`; `TIMEOUT_MULTIPLIER=3.0` gives the agent room before tasks time out.
- **Context window.** Agentic tasks need a large context. The model loaded with a
  262 144-token window (`ollama ps`); if you see truncation, bake a bigger `num_ctx`
  into a custom Modelfile.
- **Concurrency vs. VRAM.** Each concurrent trial issues model calls to the *same* Ollama
  instance, which serializes generation. High `-n` speeds up container/verifier work but
  not token generation.
- **First run is slow** — Harbor downloads the dataset and builds task Docker images once.
- **Dataset id.** If `terminal-bench@2.0` doesn't resolve, try
  `-d terminal-bench/terminal-bench-2`, or `harbor datasets list`
  (see https://hub.harborframework.com/datasets).
- **Networking.** The agent runs on the host, so `localhost:11434` is reachable. If you
  later sandbox the agent's network, allow it with `--allow-agent-host localhost`.
