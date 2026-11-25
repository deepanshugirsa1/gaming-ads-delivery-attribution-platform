"""Rewrite the measured-numbers block in the README from build artifacts.

Every number in the README that describes this project's scale or test coverage is
written by this script from dbt's run_results.json, the generator manifest, and the
lint report. None of them is typed by hand.

That is a deliberate guard rather than a convenience. A README number typed once and
never revisited is how a repository ends up claiming a model count it no longer has,
or a passing build that has not run in months -- and being unable to defend a number
on your own project is worse than not having published it.

Run after `dbt build`:
    python scripts/update_readme_stats.py
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(HERE, "README.md")
START = "<!-- STATS:START -->"
END = "<!-- STATS:END -->"


def load(path: str):
    full = os.path.join(HERE, path)
    if not os.path.exists(full):
        return None
    try:
        return json.load(open(full))
    except (json.JSONDecodeError, OSError):
        return None


def main() -> int:
    run_results = load(os.path.join("target", "run_results.json"))
    manifest = load(os.path.join("data", "ads", "_manifest.json"))
    lint = load("lint_report.json")
    validation = load("validation_report.json")
    quality = load("quality_report.json")

    lines: list[str] = []

    if run_results:
        counts: dict[str, int] = {}
        models = tests = seeds = 0
        for result in run_results.get("results", []):
            counts[result.get("status", "unknown")] = counts.get(result.get("status", "unknown"), 0) + 1
            uid = result.get("unique_id", "")
            if uid.startswith("model."):
                models += 1
            elif uid.startswith("test."):
                tests += 1
            elif uid.startswith("seed."):
                seeds += 1
        total = sum(counts.values())
        passed = counts.get("success", 0) + counts.get("pass", 0)
        failed = counts.get("fail", 0) + counts.get("error", 0)
        elapsed = run_results.get("elapsed_time")
        target = (run_results.get("args", {}) or {}).get("target", "unknown")

        lines.append(f"**Last `dbt build`** — target `{target}`, dbt "
                     f"{run_results.get('metadata', {}).get('dbt_version', '?')}, "
                     f"{run_results.get('metadata', {}).get('generated_at', '?')}")
        lines.append("")
        lines.append(f"- `PASS={passed}` of {total} nodes, `FAIL={failed}`, "
                     f"`WARN={counts.get('warn', 0)}`, `SKIP={counts.get('skipped', 0)}`")
        lines.append(f"- {models} models, {tests} tests, {seeds} seeds"
                     + (f", {elapsed:.0f}s wall clock" if elapsed else ""))
    else:
        lines.append("**Last `dbt build`** — not run yet. Run "
                     "`dbt build --profiles-dir .` then "
                     "`python scripts/update_readme_stats.py`.")

    if lint:
        lines.append(f"- lint: {lint.get('models')} models, "
                     f"{lint.get('singular_tests')} singular tests, DAG depth "
                     f"{lint.get('dag_depth')}, "
                     f"{len(lint.get('failures', []))} problems")

    if manifest:
        rows = manifest.get("row_counts", {})
        lines.append("")
        lines.append(f"**Generated feeds** — scale {manifest.get('scale')}, "
                     f"seed {manifest.get('seed')}, "
                     f"{manifest.get('total_rows', 0):,} rows total")
        lines.append("")
        lines.append("| feed | rows |")
        lines.append("|---|---:|")
        for name, count in rows.items():
            lines.append(f"| `{name}` | {count:,} |")

    if validation:
        lines.append("")
        lines.append(f"- generated-data checks: {validation.get('checks_run')} run, "
                     f"{validation.get('checks_failed')} failed")

    if quality:
        lines.append(f"- quality gate: **{str(quality.get('verdict', '?')).upper()}** "
                     f"({quality.get('errors', 0)} errors, "
                     f"{quality.get('warnings', 0)} warnings)")

    lines.append("")
    lines.append(f"<sub>Block written by `scripts/update_readme_stats.py` at "
                 f"{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M')} UTC. "
                 f"No number here is typed by hand.</sub>")

    body = open(README).read()
    if START not in body or END not in body:
        print(f"  README is missing the {START} / {END} markers")
        return 1

    head, rest = body.split(START, 1)
    _, tail = rest.split(END, 1)
    open(README, "w").write(head + START + "\n" + "\n".join(lines) + "\n" + END + tail)

    print("  README stats block updated")
    for line in lines[:6]:
        if line:
            print(f"    {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
