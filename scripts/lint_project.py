"""Static checks over the dbt project: portability, graph integrity, documentation.

This is a pre-flight check, not a substitute for `dbt build`. It exists because the
project has to produce identical results on DuckDB and BigQuery, and the ways that
breaks are nearly all spelling: a cast to VARCHAR that BigQuery rejects, a
TIMESTAMP_TRUNC that DuckDB rejects, an EXTRACT(DAYOFWEEK) that both accept and
answer differently. Those are cheap to catch by reading and expensive to catch by
running a build on the warehouse that happens to be second.

Four checks:

1. Portability. Scans the SQL as written for constructs that only work on one target,
   or that work on both and mean different things. Dialect-specific SQL is allowed
   only inside macros/, where it is branched on target.type deliberately.

2. Compilation. Renders every model and test through Jinja with stub implementations
   of ref, source, var, config and the project's macros, once per target. This catches
   Jinja syntax errors, misspelled variables and missing macros without a warehouse.
   The stubs reimplement the macros rather than reading macros/*.sql, so a macro
   change needs mirroring here -- the trade-off for being able to check anything at
   all without dbt installed.

3. Graph integrity. Every ref() resolves to a real model or seed, and the dependency
   graph is acyclic.

4. Documentation coverage. Every model appears in a schema yml with a description.

Exits non-zero on any failure, so it can gate CI.

Usage:
    python scripts/lint_project.py
"""

from __future__ import annotations

import json
import os
import re
import sys

import jinja2
import yaml

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(HERE, "models")
TEST_DIR = os.path.join(HERE, "tests")
SEED_DIR = os.path.join(HERE, "seeds")

# (regex, message). Applied to SQL as written, outside macros/.
BANNED = [
    (r"\bvarchar\b",
     "cast to `string`, not `varchar` -- BigQuery has no VARCHAR type"),
    (r"\bfloat64\b",
     "FLOAT64 is BigQuery-only; use the decimal6() macro for money and rates"),
    (r"\bdayofweek\b",
     "EXTRACT(DAYOFWEEK) numbers the week from 1 on BigQuery and 0 on DuckDB; "
     "derive the weekday from a known date with mod() instead"),
    (r"\bqualify\b",
     "QUALIFY support differs; filter a row_number() in an outer select"),
    (r"(?<!dbt\.)\bdatediff\s*\(",
     "use {{ dbt.datediff(...) }} rather than a bare datediff()"),
    (r"(?<!dbt\.)\bdateadd\s*\(",
     "use {{ dbt.dateadd(...) }} rather than a bare dateadd()"),
    (r"(?<!dbt\.)\bdate_trunc\s*\(",
     "use {{ dbt.date_trunc(...) }} -- DATE_TRUNC takes a DATE on BigQuery, "
     "and timestamps need TIMESTAMP_TRUNC there"),
    (r"\btimestamp_trunc\s*\(", "BigQuery-only; use {{ dbt.date_trunc(...) }}"),
    (r"\bdate_part\s*\(", "DuckDB spelling; use extract(part from ts)"),
    (r"\bsafe_divide\s*\(", "BigQuery-only; use the safe_div() macro"),
    (r"\bapprox_quantiles\s*\(", "BigQuery-only; use the pctl() macro"),
    (r"\bquantile_cont\s*\(", "DuckDB-only; use the pctl() macro"),
    (r"\bstring_agg\s*\(|\blistagg\s*\(", "aggregate string concatenation differs; avoid"),
    (r"\bifnull\s*\(|\bnvl\s*\(", "use coalesce()"),
    (r"\|\|", "`||` string concatenation differs; use concat() or avoid"),
    (r"::", "PostgreSQL cast syntax is not portable; use cast(x as type)"),
    (r"interval\s+'", "interval literals differ; use {{ dbt.dateadd(...) }}"),
    (r"\bgetdate\s*\(|\bsysdate\b", "non-portable clock function"),
]


def sql_files(root: str) -> list[str]:
    out = []
    for base, _, files in os.walk(root):
        for f in files:
            if f.endswith(".sql"):
                out.append(os.path.join(base, f))
    return sorted(out)


def strip_comments(sql: str) -> str:
    """Banned constructs named in an explanatory comment are not violations."""
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"--[^\n]*", " ", sql)
    sql = re.sub(r"\{#.*?#\}", " ", sql, flags=re.S)
    return sql


class Stub:
    """Minimal stand-ins for the dbt macros the models call."""

    def __init__(self, target_type: str, project_vars: dict) -> None:
        self.target_type = target_type
        self.vars = project_vars

    # --- dbt cross-database macros ---
    def datediff(self, start, end, part):
        if self.target_type == "bigquery":
            return f"timestamp_diff({end}, {start}, {part})"
        return f"date_diff('{part}', {start}, {end})"

    def dateadd(self, part, interval, from_date):
        if self.target_type == "bigquery":
            return f"timestamp_add({from_date}, interval {interval} {part})"
        return f"({from_date} + ({interval}) * interval '1 {part}')"

    def date_trunc(self, part, value):
        if self.target_type == "bigquery":
            return f"timestamp_trunc({value}, {part})"
        return f"date_trunc('{part}', {value})"

    # --- this project's macros ---
    def safe_div(self, num, den):
        return f"case when ({den}) is null or ({den}) = 0 then null else ({num}) * 1.0 / ({den}) end"

    def pctl(self, col, frac):
        if self.target_type == "bigquery":
            return f"approx_quantiles({col}, 100)[offset({int(round(frac * 100))})]"
        return f"quantile_cont({col}, {frac})"

    def decimal6(self):
        return "numeric" if self.target_type == "bigquery" else "decimal(18, 6)"

    def ads_raw(self, table_name):
        if self.target_type == "bigquery":
            return f"`proj.{self.vars['ads_raw_dataset']}.{table_name}`"
        return f"read_csv_auto('{self.vars['ads_raw_path']}/{table_name}/*.csv.gz', all_varchar=true)"


def build_env(target_type: str, project_vars: dict, refs_seen: list):
    stub = Stub(target_type, project_vars)

    class Target:
        type = target_type
        project = "proj"
        schema = "main"

    class Exceptions:
        @staticmethod
        def raise_compiler_error(msg):
            raise jinja2.TemplateError(f"raise_compiler_error reached: {msg}")

    def ref(name, *_a, **_k):
        refs_seen.append(name)
        return f"`{name}`"

    def source(src, name):
        refs_seen.append(f"{src}.{name}")
        return f"`{src}.{name}`"

    def var(name, default=None):
        if name in project_vars:
            return project_vars[name]
        if default is not None:
            return default
        raise jinja2.TemplateError(f"var('{name}') is not defined in dbt_project.yml")

    env = jinja2.Environment(undefined=jinja2.StrictUndefined)
    env.globals.update(
        ref=ref,
        source=source,
        var=var,
        config=lambda **_k: "",
        this="`this_model`",
        is_incremental=lambda: True,
        target=Target(),
        dbt=stub,
        exceptions=Exceptions(),
        safe_div=stub.safe_div,
        pctl=stub.pctl,
        decimal6=stub.decimal6,
        ads_raw=stub.ads_raw,
        log=lambda *a, **k: "",
        run_query=lambda *a, **k: None,
    )
    return env


def main() -> int:
    project = yaml.safe_load(open(os.path.join(HERE, "dbt_project.yml")))
    project_vars = project.get("vars", {})

    model_files = sql_files(MODEL_DIR)
    test_files = sql_files(TEST_DIR)
    all_files = model_files + test_files

    model_names = {os.path.splitext(os.path.basename(f))[0] for f in model_files}
    seed_names = {
        os.path.splitext(f)[0] for f in os.listdir(SEED_DIR) if f.endswith(".csv")
    } if os.path.isdir(SEED_DIR) else set()
    buildable = model_names | seed_names

    failures: list[str] = []
    notes: list[str] = []

    # ---------- 1. portability ----------
    for path in all_files:
        rel = os.path.relpath(path, HERE)
        body = strip_comments(open(path).read()).lower()
        for pattern, message in BANNED:
            for m in re.finditer(pattern, body):
                snippet = body[max(0, m.start() - 30):m.end() + 30].replace("\n", " ")
                failures.append(f"{rel}: {message}\n      ...{snippet.strip()}...")

    # ---------- 2. compilation, once per target ----------
    dependencies: dict[str, set[str]] = {}
    for target_type in ("duckdb", "bigquery"):
        for path in all_files:
            rel = os.path.relpath(path, HERE)
            name = os.path.splitext(os.path.basename(path))[0]
            refs_seen: list[str] = []
            env = build_env(target_type, project_vars, refs_seen)
            try:
                rendered = env.from_string(open(path).read()).render()
            except Exception as exc:  # noqa: BLE001 - report any template failure
                failures.append(f"{rel}: fails to compile on {target_type}: {exc}")
                continue
            if not rendered.strip():
                failures.append(f"{rel}: compiles to empty SQL on {target_type}")
            if target_type == "duckdb" and path in model_files:
                dependencies[name] = {r for r in refs_seen if "." not in r}

    # ---------- 3. graph integrity ----------
    for name, deps in dependencies.items():
        for dep in deps:
            if dep not in buildable:
                failures.append(f"{name}: ref('{dep}') does not resolve to a model or seed")

    colour = {}

    def visit(node: str, stack: list[str]) -> None:
        if colour.get(node) == "done":
            return
        if colour.get(node) == "open":
            failures.append("dependency cycle: " + " -> ".join(stack + [node]))
            return
        colour[node] = "open"
        for dep in sorted(dependencies.get(node, ())):
            if dep in dependencies:
                visit(dep, stack + [node])
        colour[node] = "done"

    for node in sorted(dependencies):
        visit(node, [])

    # depth of the DAG, as a sanity signal that layering is real
    depth_cache: dict[str, int] = {}

    def depth(node: str) -> int:
        if node in depth_cache:
            return depth_cache[node]
        depth_cache[node] = 0  # cycle guard; cycles already reported
        deps = [d for d in dependencies.get(node, ()) if d in dependencies]
        depth_cache[node] = 1 + max((depth(d) for d in deps), default=0)
        return depth_cache[node]

    max_depth = max((depth(n) for n in dependencies), default=0)

    # ---------- 4. documentation coverage ----------
    documented: dict[str, str] = {}
    for base, _, files in os.walk(MODEL_DIR):
        for f in files:
            if f.endswith((".yml", ".yaml")):
                doc = yaml.safe_load(open(os.path.join(base, f))) or {}
                for entry in doc.get("models", []) or []:
                    documented[entry["name"]] = (entry.get("description") or "").strip()

    for name in sorted(model_names):
        if name not in documented:
            failures.append(f"{name}: not documented in any schema yml")
        elif not documented[name]:
            failures.append(f"{name}: documented with an empty description")

    for name in sorted(documented):
        if name not in model_names:
            failures.append(f"schema yml documents '{name}', which is not a model file")

    # ---------- report ----------
    notes.append(f"models: {len(model_names)}")
    notes.append(f"singular tests: {len(test_files)}")
    notes.append(f"seeds: {len(seed_names)}")
    notes.append(f"dag depth: {max_depth}")
    notes.append(f"documented models: {len(documented)}")

    report = {
        "models": len(model_names),
        "singular_tests": len(test_files),
        "seeds": len(seed_names),
        "dag_depth": max_depth,
        "failures": failures,
    }
    with open(os.path.join(HERE, "lint_report.json"), "w") as fh:
        json.dump(report, fh, indent=2)

    print("  " + "   ".join(notes))
    print(f"  compiled {len(all_files)} files against duckdb and bigquery")
    if failures:
        print(f"\n  {len(failures)} problem(s):")
        for f in failures:
            print(f"    - {f}")
        return 1
    print("\n  no portability, compilation, graph or documentation problems found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
