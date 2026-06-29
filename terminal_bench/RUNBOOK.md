# Terminal-Bench 2.0 — Operations Runbook

How to run the benchmark **and** the Grafana monitoring stack, end to end, on this
host. This is the operational companion to `README.md` (which explains *what* the
system is). Read this when you just want to **run it**.

```
 Harbor (host) ──LiteLLM──▶ Ollama localhost:11434 (gemma4:31b-ctx32k)
      │
      ├──tmux──▶ task container (amd64 via QEMU) ──▶ verifier → pass/fail
      │                                                      │
      └────────── writes jobs/<job>/.../result.json ─────────┘
                              │
        exporter.py :9101 ──▶ Prometheus :9090 ──▶ Grafana :3000 (dashboard)
```

---

## 0. Host facts you must know first

| Fact | Consequence |
|------|-------------|
| Host is **ARM64 (aarch64)**; TB2 task images are **amd64-only** | You **must** install QEMU binfmt emulation before every run after a reboot (Step 1). Without it, every trial exits `255 / exec format error`. |
| Docker group membership may post-date your shell | Docker is invoked via `sg docker -c "…"` in the monitoring scripts. If `docker ps` fails in your shell, prefix with `sg docker -c`. |
| The model is a **local 31B** served by Ollama | Slow on long rollouts. Keep `N_TASKS` small and `N_CONCURRENT=1`. |
| Custom model `gemma4:31b-ctx32k` = 32K context (vs 256K) | Faster prefill. Built from `Modelfile.gemma4-ctx32k`. |

---

## 1. One-time / per-reboot prerequisites

Run these in order. Items marked **(per reboot)** must be re-applied every time the
machine restarts; the rest are one-time.

```bash
# 1a. QEMU emulation for amd64 task images  — (per reboot, NOT persistent)
docker run --privileged --rm tonistiigi/binfmt --install amd64

# 1b. Tooling (one-time) — uv + Harbor
curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install harbor

# 1c. Docker socket access (one-time; then re-login)
sudo usermod -aG docker $USER && newgrp docker
docker ps                      # must succeed

# 1d. Ollama + the model (one-time)
ollama serve                   # if not already running (often already up)
ollama pull gemma4:31b
ollama create gemma4:31b-ctx32k -f Modelfile.gemma4-ctx32k   # the 32K-ctx build used by config.env
```

> If `ollama ps` later shows the wrong context size or you change the Modelfile,
> re-run the `ollama create …` line.

---

## 2. Run the benchmark

```bash
cd ~/terminal_bench

./preflight.sh        # verifies uv, harbor, docker, ollama, model, + live inference
./run_benchmark.sh    # runs 5 tasks by default (see config.env)
```

`preflight.sh` must print **“All checks passed”** before you proceed. If it fails,
fix the ✗ items — the most common one after a reboot is the QEMU step (1a) or
`ollama serve` not running.

### Tuning a run

All knobs live in `config.env`. Edit it, or override any variable inline:

```bash
N_TASKS=0 N_CONCURRENT=1 ./run_benchmark.sh     # full 89-task suite (N_TASKS=0 means ALL)
INCLUDE_GLOB='hello-world' ./run_benchmark.sh   # a single named task
./run_benchmark.sh -i 'fix-*'                   # extra flags pass straight through to harbor
```

Key `config.env` values:

| Var | Default | Notes |
|-----|---------|-------|
| `OLLAMA_MODEL` | `gemma4:31b-ctx32k` | Must match a tag from `ollama list`. |
| `N_TASKS` | `5` | `""` or `0` = all 89 tasks. |
| `N_CONCURRENT` | `1` | Keep at 1 — calls serialize on one Ollama instance. |
| `N_ATTEMPTS` | `1` | `>1` enables pass^k / best-of-k. |
| `TIMEOUT_MULTIPLIER` | `1.0` | Bump to `3.0` if a slow model times out tasks. |
| `INCLUDE_GLOB` | `""` | Task-name filter. |

Output lands in `jobs/<job-name>/` (e.g. `gemma4-31b-20260628-203500`).

### Inspect results

```bash
python3 summarize_results.py                    # newest job under ./jobs
python3 summarize_results.py jobs/<job-name>    # a specific job
```

Compare against the public TB2 leaderboard: https://www.tbench.ai/leaderboard/terminal-bench/2.0

---

## 3. Grafana monitoring dashboard

A self-contained observability stack lives in `monitoring/`. It tracks per-task
status / reward / duration, run aggregates, GPU, and Ollama state — live as a run
progresses.

### Components

| Component | Port | What it is |
|-----------|------|------------|
| `exporter.py` | **9101** | Host Python process (stdlib only). Parses `jobs/*/.../result.json`, GPU via `nvidia-smi`, Ollama via `/api/ps`. |
| Prometheus | **9090** | Docker container `tb2-prometheus`, scrapes the exporter every 5s. |
| Grafana | **3000** | Docker container `tb2-grafana`. Dashboard auto-provisioned. |

Both containers use `network_mode: host` so they reach the host exporter on
`localhost`. The Prometheus datasource uid is `tb2prom`.

### Start

```bash
cd ~/terminal_bench/monitoring
./start_monitoring.sh
```

This launches the exporter (as a `nohup` background process → `exporter.log`,
pid in `exporter.pid`) and brings up Prometheus + Grafana via
`sg docker -c "docker compose up -d"`.

### Open the dashboard

- **Grafana:** http://localhost:3000  → login `admin` / `admin` (or just view
  anonymously — anonymous Viewer is enabled).
- Dashboard: **“Terminal-Bench 2.0 — Run Tracker”** (uid `tb2-tracker`), found
  under Dashboards. It has a **`$job`** template variable at the top that defaults
  to the newest job — switch it to view an older run.
- **Prometheus** (raw queries / target health): http://localhost:9090 →
  Status → Targets should show `tb2` endpoint `localhost:9101` as **UP**.
- **Exporter** (sanity check the raw metrics): http://localhost:9101/metrics

> Run the benchmark and the monitoring stack **at the same time**: start monitoring
> first (or any time), then `./run_benchmark.sh`. The exporter picks up new jobs
> automatically as `result.json` files appear.

### Stop

```bash
cd ~/terminal_bench/monitoring
./stop_monitoring.sh
```

Stops the exporter (via `exporter.pid`) and runs `docker compose down`. The
Prometheus/Grafana data volumes (`tb2-prom-data`, `tb2-grafana-data`) persist, so
history survives a restart.

### Add or change metrics

Edit the `collect_*` functions in `monitoring/exporter.py`, then restart **only**
the exporter — no Docker rebuild needed:

```bash
kill "$(cat monitoring/exporter.pid)" 2>/dev/null
cd ~/terminal_bench/monitoring && nohup python3 exporter.py > exporter.log 2>&1 & echo $! > exporter.pid
```

Grafana/Prometheus use native arm64 images, so no QEMU is involved in the
monitoring stack.

---

## 4. Quick start (the whole thing)

```bash
# --- per reboot ---
docker run --privileged --rm tonistiigi/binfmt --install amd64

# --- monitoring (leave running in one terminal) ---
cd ~/terminal_bench/monitoring && ./start_monitoring.sh
#   → open http://localhost:3000  ("Terminal-Bench 2.0 — Run Tracker")

# --- benchmark (another terminal) ---
cd ~/terminal_bench
./preflight.sh && ./run_benchmark.sh

# --- results ---
python3 summarize_results.py
```

---

## 5. Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| Every trial errors `255` / `exec format error` before the model is called | QEMU binfmt not installed. Re-run Step 1a (not persistent across reboots). |
| `preflight.sh` ✗ docker | `sudo usermod -aG docker $USER && newgrp docker`, then re-login. In an old shell use `sg docker -c "docker ps"`. |
| `preflight.sh` ✗ ollama not responding | `ollama serve`. |
| `preflight.sh` ✗ model not pulled | `ollama pull gemma4:31b` then `ollama create gemma4:31b-ctx32k -f Modelfile.gemma4-ctx32k`. |
| Grafana shows “No data” | Check Prometheus target is UP (http://localhost:9090 → Targets) and the exporter responds (`curl localhost:9101/metrics`). Restart exporter if down. Confirm the `$job` variable points at a job that has results. |
| Grafana port 3000 / 9090 in use | Another service is bound. `./stop_monitoring.sh`, free the port, restart. |
| `docker compose` not found | Scripts fall back to `docker-compose`; ensure one is installed. |
| Dataset `terminal-bench@2.0` won't resolve | Try `-d terminal-bench/terminal-bench-2`, or list with `harbor datasets list`. |
| First run hangs for a long time | Expected — Harbor downloads the dataset and builds task images once; subsequent runs reuse them. |
