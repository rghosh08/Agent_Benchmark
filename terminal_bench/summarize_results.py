#!/usr/bin/env python3
"""Summarize a Harbor / Terminal-Bench job directory into a pass-rate report.

Usage:
    python3 summarize_results.py [JOB_DIR]

If JOB_DIR is omitted, the most recent job under ./jobs is used. The script is
schema-tolerant: it walks every JSON the job produced and infers, per trial,
whether the verifier passed, then prints overall accuracy plus a per-task table.
"""
from __future__ import annotations
import json
import sys
from pathlib import Path

# Field names Harbor / Terminal-Bench have used for the pass/fail signal.
PASS_KEYS = ("is_resolved", "resolved", "passed", "success", "is_correct", "reward")
NAME_KEYS = ("task_name", "task_id", "name", "id", "task")


def newest_job(jobs_root: Path) -> Path | None:
    cands = [p for p in jobs_root.iterdir() if p.is_dir()] if jobs_root.is_dir() else []
    return max(cands, key=lambda p: p.stat().st_mtime) if cands else None


def truthy(v) -> bool | None:
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v > 0
    if isinstance(v, str):
        return v.strip().lower() in {"true", "pass", "passed", "resolved", "yes", "1"}
    return None


def extract(obj):
    """Yield (task_name, passed_bool) pairs found anywhere in a JSON blob."""
    if isinstance(obj, dict):
        passed = next((truthy(obj[k]) for k in PASS_KEYS if k in obj), None)
        if passed is not None:
            name = next((str(obj[k]) for k in NAME_KEYS if k in obj), None)
            yield name, passed
        for v in obj.values():
            yield from extract(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from extract(v)


def main() -> int:
    if len(sys.argv) > 1:
        job_dir = Path(sys.argv[1])
    else:
        job_dir = newest_job(Path(__file__).parent / "jobs")
        if not job_dir:
            print("No job directory given and none found under ./jobs", file=sys.stderr)
            return 2
    if not job_dir.is_dir():
        print(f"Not a directory: {job_dir}", file=sys.stderr)
        return 2

    results: dict[str, bool] = {}
    anon = 0
    for jf in sorted(job_dir.rglob("*.json")):
        try:
            data = json.loads(jf.read_text())
        except Exception:
            continue
        for name, passed in extract(data):
            if name is None:
                name = f"<trial-{anon}>"
                anon += 1
            # If a task shows up more than once, count it solved if any attempt passed.
            results[name] = results.get(name, False) or passed

    print(f"\nJob: {job_dir}")
    if not results:
        print("No verifier results found yet. The job may still be running, or")
        print("inspect the raw output:  ls -R", job_dir)
        return 1

    total = len(results)
    solved = sum(1 for v in results.values() if v)
    width = max(len(k) for k in results)
    print("─" * (width + 10))
    for name in sorted(results):
        mark = "\033[32mPASS\033[0m" if results[name] else "\033[31mFAIL\033[0m"
        print(f"  {name.ljust(width)}  {mark}")
    print("─" * (width + 10))
    print(f"  Accuracy: {solved}/{total} = {100*solved/total:.1f}%\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
