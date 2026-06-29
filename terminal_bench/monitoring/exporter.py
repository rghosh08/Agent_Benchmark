#!/usr/bin/env python3
"""
Terminal-Bench 2.0 Prometheus exporter.

Scrapes three sources and exposes them at http://0.0.0.0:9101/metrics :
  1. Harbor job results under JOBS_DIR (per-task status, reward, duration; aggregates)
  2. GPU utilisation via `nvidia-smi` (GB10 reports some fields as [N/A]; those are skipped)
  3. Loaded model info via Ollama's /api/ps (vram, context window)

Pure stdlib — no pip installs. Designed to run on the host so Prometheus
(in a host-network container) can scrape localhost:9101.
"""
import json
import os
import glob
import subprocess
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

JOBS_DIR = os.environ.get("JOBS_DIR", "/home/rghosh8/terminal_bench/jobs")
OLLAMA = os.environ.get("OLLAMA_API_BASE", "http://localhost:11434")
PORT = int(os.environ.get("EXPORTER_PORT", "9101"))


def _iso(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def task_status(result):
    """Map a per-task result.json dict to (status, reward)."""
    ex = result.get("exception_info")
    if ex:
        et = (ex.get("exception_type") or "error").lower()
        if "timeout" in et:
            return "timeout", 0.0
        return "errored", 0.0
    vr = result.get("verifier_result")
    if vr is None:
        return "running", 0.0
    # verifier_result shape varies; pull a reward-ish number
    reward = 0.0
    if isinstance(vr, dict):
        for k in ("reward", "score", "value"):
            if isinstance(vr.get(k), (int, float)):
                reward = float(vr[k])
                break
        if "passed" in vr and isinstance(vr["passed"], bool):
            reward = 1.0 if vr["passed"] else 0.0
    elif isinstance(vr, (int, float)):
        reward = float(vr)
    return ("passed" if reward >= 1.0 else "failed"), reward


def collect_jobs():
    lines = []
    job_dirs = sorted(
        [d for d in glob.glob(os.path.join(JOBS_DIR, "*")) if os.path.isdir(d)],
        key=os.path.getmtime,
    )
    latest = os.path.basename(job_dirs[-1]) if job_dirs else ""
    lines.append("# HELP tb_latest_job_info Latest job (value always 1)")
    lines.append("# TYPE tb_latest_job_info gauge")
    if latest:
        lines.append(f'tb_latest_job_info{{job="{latest}"}} 1')

    lines.append("# HELP tb_task_reward Per-task reward (0..1)")
    lines.append("# TYPE tb_task_reward gauge")
    lines.append("# HELP tb_task_duration_seconds Per-task wall-clock duration")
    lines.append("# TYPE tb_task_duration_seconds gauge")
    lines.append("# HELP tb_task_state Per-task state (1 = task is in this state)")
    lines.append("# TYPE tb_task_state gauge")

    agg = {}  # job -> Counter dict
    STATES = ["passed", "failed", "timeout", "errored", "running"]
    for jd in job_dirs:
        job = os.path.basename(jd)
        agg.setdefault(job, {s: 0 for s in STATES})
        agg[job]["total"] = 0
        for td in glob.glob(os.path.join(jd, "*")):
            if not os.path.isdir(td):
                continue
            task = os.path.basename(td).split("__")[0]
            rj = os.path.join(td, "result.json")
            if os.path.exists(rj):
                try:
                    res = json.load(open(rj))
                except Exception:
                    continue
                status, reward = task_status(res)
                st, ft = _iso(res.get("started_at")), _iso(res.get("finished_at"))
                dur = (ft - st).total_seconds() if st and ft else 0.0
                lines.append(f'tb_task_reward{{job="{job}",task="{task}"}} {reward}')
                lines.append(f'tb_task_duration_seconds{{job="{job}",task="{task}"}} {dur:.1f}')
            else:
                status = "running"
            for s in STATES:
                lines.append(
                    f'tb_task_state{{job="{job}",task="{task}",state="{s}"}} {1 if s == status else 0}'
                )
            agg[job][status] = agg[job].get(status, 0) + 1
            agg[job]["total"] += 1

    for metric, key in [
        ("tb_tasks_total", "total"),
        ("tb_tasks_passed", "passed"),
        ("tb_tasks_failed", "failed"),
        ("tb_tasks_timeout", "timeout"),
        ("tb_tasks_errored", "errored"),
        ("tb_tasks_running", "running"),
    ]:
        lines.append(f"# TYPE {metric} gauge")
        for job, c in agg.items():
            lines.append(f'{metric}{{job="{job}"}} {c.get(key, 0)}')

    # pass rate over completed (passed/failed) tasks
    lines.append("# HELP tb_pass_rate Passed / (passed+failed+timeout+errored)")
    lines.append("# TYPE tb_pass_rate gauge")
    for job, c in agg.items():
        done = c["passed"] + c["failed"] + c["timeout"] + c["errored"]
        rate = (c["passed"] / done) if done else 0.0
        lines.append(f'tb_pass_rate{{job="{job}"}} {rate:.4f}')
    return lines


def collect_gpu():
    lines = []
    fields = "utilization.gpu,utilization.memory,temperature.gpu,power.draw,memory.used,memory.total"
    try:
        out = subprocess.run(
            ["nvidia-smi", f"--query-gpu={fields}", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=8,
        ).stdout.strip()
    except Exception:
        return lines
    names = ["gpu_utilization_percent", "gpu_mem_utilization_percent",
             "gpu_temperature_celsius", "gpu_power_watts",
             "gpu_memory_used_mb", "gpu_memory_total_mb"]
    for i, row in enumerate(out.splitlines()):
        vals = [v.strip() for v in row.split(",")]
        for name, v in zip(names, vals):
            try:
                fv = float(v)
            except Exception:
                continue  # skip [N/A] (GB10 unified memory)
            lines.append(f"# TYPE {name} gauge")
            lines.append(f'{name}{{gpu="{i}"}} {fv}')
    return lines


def collect_ollama():
    lines = []
    try:
        with urllib.request.urlopen(f"{OLLAMA}/api/ps", timeout=5) as r:
            data = json.load(r)
    except Exception:
        return lines
    lines.append("# HELP ollama_model_vram_bytes VRAM used by loaded model")
    lines.append("# TYPE ollama_model_vram_bytes gauge")
    lines.append("# TYPE ollama_model_context_length gauge")
    lines.append("# TYPE ollama_model_loaded gauge")
    for m in data.get("models", []):
        name = m.get("name", "?")
        lines.append(f'ollama_model_loaded{{model="{name}"}} 1')
        if "size_vram" in m:
            lines.append(f'ollama_model_vram_bytes{{model="{name}"}} {m["size_vram"]}')
        if m.get("context_length"):
            lines.append(f'ollama_model_context_length{{model="{name}"}} {m["context_length"]}')
    return lines


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404); self.end_headers(); return
        body = "\n".join(collect_jobs() + collect_gpu() + collect_ollama()) + "\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *a):
        pass  # quiet


if __name__ == "__main__":
    print(f"tb2 exporter on :{PORT}  jobs={JOBS_DIR}  ollama={OLLAMA}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
