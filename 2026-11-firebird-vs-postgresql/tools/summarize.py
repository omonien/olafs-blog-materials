#!/usr/bin/env python3
"""Collects the RESULT lines of the raw logs into medians per platform, test, engine and parameters.

Every log line "RESULT key=value ..." is one measurement; the "LOAD ..." line before it records the load of the
Mac (and of the Docker VM or the Windows VM) at its start. The log's file name gives the platform and the series:
"windows-2026-11-04.log" is the main series of Windows, "windows-firedac-2026-11-04.log" the FireDAC series, whose
.NET runs ran at the same time as the FireDAC runs and are therefore kept apart from the main series. Lines without
"driver=" come from the .NET program. Writes results/summary.md (tables with median, range, number of runs and
load), results/comparison.md and results/medians.json (input of charts/make_charts.py).
Usage: python3 tools/summarize.py [results-dir]
"""
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

PAIR = re.compile(r'(\w+)=("([^"]*)"|\S+)')

# Parameters that tell runs of the same test apart.
KEYS = {
    "fill": [], "json-setup": [], "oltp-setup": ["scale"], "size": ["table"],
    "read": ["zoned", "wirecrypt"], "insert": ["durability", "clients"], "bulk": ["mode"],
    "oltp": ["script", "clients", "cursor"], "json": ["query", "parallel"],
}
# The value a test is judged by; higher is better unless listed in LOWER.
METRIC = {"fill": "seconds", "json-setup": "load_s", "oltp-setup": "seconds", "size": "database_mb",
          "read": "rows_per_s", "insert": "tps", "bulk": "rows_per_s", "oltp": "tps", "json": "ms"}


def parse(line):
    return {m.group(1): m.group(3) if m.group(3) is not None else m.group(2) for m in PAIR.finditer(line)}


def records(results_dir):
    out = []
    for path in sorted((results_dir / "raw").glob("*.log")):
        platform, *rest = path.stem.split("-")
        series = "-".join(part for part in rest if not part.isdigit()) or "main"
        load = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("LOAD "):
                load = parse(line[5:])
            elif line.startswith("RESULT "):
                r = parse(line[7:])
                r["platform"] = platform
                r["series"] = series
                r.setdefault("driver", "dotnet")
                r["log"] = path.name
                if "mac" in load:
                    r["mac_load"] = float(load["mac"].split()[0])
                if "docker_vm" in load and load["docker_vm"]:
                    r["vm_load"] = float(load["docker_vm"].split()[0])
                if "vm_cpu_percent" in load:
                    r["vm_cpu"] = float(load["vm_cpu_percent"])
                out.append(r)
    return out


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def per_unit_us(r, field):
    """CPU microseconds per row or transaction, over the whole measured run."""
    seconds = number(r.get(field))
    units = number(r.get("total_txns") or r.get("rows"))
    if seconds is None or not units:
        return None
    return seconds / units * 1e6


def summarize(recs):
    groups = defaultdict(list)
    for r in recs:
        test = r["test"]
        key = (r["platform"], r["series"], test, r["engine"], r["driver"]) + tuple(r.get(k, "") for k in KEYS.get(test, []))
        groups[key].append(r)
    rows = []
    for key, rs in sorted(groups.items()):
        platform, series, test, engine, driver, *params = key
        metric = METRIC.get(test, "seconds")
        values = [number(r.get(metric)) for r in rs if number(r.get(metric)) is not None]
        if not values:
            continue
        row = {"platform": platform, "series": series, "test": test, "engine": engine, "driver": driver,
               "params": dict(zip(KEYS.get(test, []), params)), "metric": metric, "n": len(values),
               "median": statistics.median(values), "min": min(values), "max": max(values)}
        for extra in ("p50_ms", "p95_ms", "p99_ms", "lat_avg_ms", "retries", "failed", "load_s", "commit_s"):
            xs = [number(r.get(extra)) for r in rs if number(r.get(extra)) is not None]
            if xs:
                row[extra] = statistics.median(xs)
        for field, name in (("server_cpu_s", "server_us_per_unit"), ("client_cpu_s", "client_us_per_unit")):
            xs = [v for v in (per_unit_us(r, field) for r in rs) if v is not None]
            if xs and test in ("read", "insert", "bulk", "oltp"):
                row[name] = statistics.median(xs)
        if test == "json":
            xs = [number(r.get("server_cpu_s")) for r in rs if number(r.get("server_cpu_s")) is not None]
            if xs:
                row["server_cpu_s"] = statistics.median(xs)
            row["answers"] = sorted({r.get("answer", "") for r in rs})
        for field in ("mac_load", "vm_load", "vm_cpu"):
            xs = [r[field] for r in rs if field in r]
            if xs:
                row[field] = [min(xs), max(xs)]
        rows.append(row)
    return rows


def fmt(v, digits=0):
    if v is None:
        return ""
    return f"{v:,.{digits}f}"


def table(rows, section, test, columns):
    sel = [r for r in rows if (r["platform"], r["series"]) == section and r["test"] == test]
    if not sel:
        return ""
    head = "| " + " | ".join(c[0] for c in columns) + " |\n|" + "|".join(" --- " if i < 3 else " ---: " for i, _ in enumerate(columns)) + "|\n"
    body = "".join("| " + " | ".join(c[1](r) for c in columns) + " |\n" for r in sel)
    return f"### {section_title(section)}: {test}\n\n{head}{body}\n"


def section_title(section):
    platform, series = section
    return platform if series == "main" else f"{platform}, {series}"


def load_text(r):
    parts = []
    if "mac_load" in r:
        parts.append(f"Mac {r['mac_load'][0]:.0f}-{r['mac_load'][1]:.0f}")
    if "vm_load" in r:
        parts.append(f"VM {r['vm_load'][0]:.1f}-{r['vm_load'][1]:.1f}")
    if "vm_cpu" in r:
        parts.append(f"VM CPU {r['vm_cpu'][0]:.0f}-{r['vm_cpu'][1]:.0f} %")
    return ", ".join(parts)


def main():
    results_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "results"
    rows = summarize(records(results_dir))
    (results_dir / "medians.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    params = lambda r: " ".join(f"{k}={v}" for k, v in r["params"].items() if v)
    med = lambda d=0: (lambda r: f"{fmt(r['median'], d)} ({fmt(r['min'], d)} to {fmt(r['max'], d)}, n={r['n']})")
    cpu = lambda f: (lambda r: fmt(r.get(f), 1))
    lat = lambda f: (lambda r: fmt(r.get(f), 2))
    common = [("Engine", lambda r: r["engine"]), ("Driver", lambda r: r["driver"]), ("Parameters", params)]
    out = ["# Summary of the raw logs\n", "Generated by `tools/summarize.py` from `results/raw/*.log`. Median over all runs, range in brackets. "
           "CPU per unit: CPU time of the server processes (or of the client) divided by all rows or transactions of the run, warm-up included.\n"]
    for section in sorted({(r["platform"], r["series"]) for r in rows}):
        out.append(f"\n## {section_title(section)}\n")
        out.append(table(rows, section, "read", common + [("Rows/s", med()), ("Server µs/row", cpu("server_us_per_unit")),
                                                            ("Client µs/row", cpu("client_us_per_unit")), ("Load", load_text)]))
        out.append(table(rows, section, "insert", common + [("Transactions/s", med(1)), ("p50 ms", lat("p50_ms")), ("p99 ms", lat("p99_ms")),
                                                              ("Server µs/txn", cpu("server_us_per_unit")), ("Load", load_text)]))
        out.append(table(rows, section, "bulk", common + [("Rows/s", med()), ("Commit s", lat("commit_s")),
                                                            ("Server µs/row", cpu("server_us_per_unit")), ("Client µs/row", cpu("client_us_per_unit")), ("Load", load_text)]))
        out.append(table(rows, section, "oltp", common + [("Transactions/s", med(1)), ("p50 ms", lat("p50_ms")), ("p95 ms", lat("p95_ms")),
                                                            ("p99 ms", lat("p99_ms")), ("Retries", lambda r: fmt(r.get("retries"))),
                                                            ("Server µs/txn", cpu("server_us_per_unit")), ("Load", load_text)]))
        out.append(table(rows, section, "json", common + [("Milliseconds", med(1)), ("Server CPU s", lambda r: fmt(r.get("server_cpu_s"), 2)),
                                                            ("Answer", lambda r: "<br>".join(r["answers"])), ("Load", load_text)]))
        for test in ("fill", "json-setup", "oltp-setup", "size"):
            out.append(table(rows, section, test, common + [(METRIC[test], med(1)), ("Load", load_text)]))
    (results_dir / "summary.md").write_text("".join(out), encoding="utf-8")
    (results_dir / "comparison.md").write_text(comparison(rows), encoding="utf-8")
    print(f"{len(rows)} groups -> {results_dir / 'summary.md'}, {results_dir / 'comparison.md'}, {results_dir / 'medians.json'}")


# Order and wording of the compact comparison: (test, parameters, label, unit).
COMPARE = [
    ("read", {"zoned": "on", "wirecrypt": "off"}, "Read 2,000,000 rows", "rows/s"),
    ("insert", {"durability": "default", "clients": "1"}, "Insert, durable, 1 client", "txn/s"),
    ("insert", {"durability": "default", "clients": "8"}, "Insert, durable, 8 clients", "txn/s"),
    ("insert", {"durability": "relaxed", "clients": "1"}, "Insert, relaxed, 1 client", "txn/s"),
    ("insert", {"durability": "relaxed", "clients": "8"}, "Insert, relaxed, 8 clients", "txn/s"),
    ("bulk", {"mode": "prepared"}, "Bulk, prepared row by row", "rows/s"),
    ("bulk", {"mode": "native"}, "Bulk, batch API / COPY", "rows/s"),
] + [("oltp", {"script": sc, "clients": c}, f"pgbench {name}, {c} client{'s' if c != '1' else ''}", "txn/s")
     for sc, name in (("select", "select-only"), ("simple", "simple-update"), ("tpcb", "TPC-B like"))
     for c in ("1", "4", "16", "64") if sc == "tpcb" or c != "64"] + [
    ("json", {"query": "lookup-index", "parallel": "on"}, "JSON: find a customer, GIN index", "ms"),
    ("json", {"query": "lookup-scan", "parallel": "on"}, "JSON: find a customer, SQL/JSON scan", "ms"),
    ("json", {"query": "lookup-like", "parallel": "on"}, "JSON: find a customer, LIKE", "ms"),
    ("json", {"query": "lookup-client", "parallel": "on"}, "JSON: find a customer, parse in the client", "ms"),
    ("json", {"query": "agg-sql", "parallel": "on"}, "JSON: sum per status, SQL/JSON", "ms"),
    ("json", {"query": "agg-sql", "parallel": "off"}, "JSON: sum per status, SQL/JSON, no parallelism", "ms"),
    ("json", {"query": "agg-client", "parallel": "on"}, "JSON: sum per status, parse in the client", "ms"),
]


def comparison(rows):
    """Median of Firebird and PostgreSQL per test and platform, with the factor in PostgreSQL's favour."""
    def get(platform, test, engine, params, series="main", driver="dotnet"):
        for r in rows:
            if (r["platform"], r["series"], r["test"], r["engine"], r["driver"]) == (platform, series, test, engine, driver) and \
                    all(r["params"].get(k) == v for k, v in params.items()):
                return r
        return None
    titles = {"mac": "macOS, Docker", "windows": "Windows 11 VM, local"}
    out = ["# Firebird and PostgreSQL side by side\n\nGenerated by `tools/summarize.py`. Median of all runs (n = runs per server); "
           "factor = how many times better PostgreSQL is (higher throughput or lower time).\n"]
    for platform in sorted({r["platform"] for r in rows if r["series"] == "main"}):
        out.append(f"\n## {titles.get(platform, platform)}\n\n| Test | Unit | Firebird | PostgreSQL | Factor | n |\n| --- | --- | ---: | ---: | ---: | ---: |\n")
        for test, params, label, unit in COMPARE:
            fb, pg = get(platform, test, "fb", params), get(platform, test, "pg", params)
            if not fb and not pg:
                continue
            digits = 1 if unit == "ms" else 0
            f = ""
            if fb and pg:
                ratio = fb["median"] / pg["median"] if unit == "ms" else pg["median"] / fb["median"]
                f = f"{ratio:.1f}"
            n = "/".join(str(x["n"]) for x in (fb, pg) if x)
            out.append(f"| {label} | {unit} | {fmt(fb['median'], digits) if fb else 'not possible'} | "
                       f"{fmt(pg['median'], digits) if pg else ''} | {f} | {n} |\n")
    # The FireDAC series: .NET and FireDAC steps alternated within the same runs, so all columns saw the same load.
    # FireDAC ran with its automatic cursor choice and, for the pgbench scripts, with CursorKind ckDefault as well.
    variants = (("dotnet", {}), ("firedac", {"cursor": "automatic"}), ("firedac", {"cursor": "default"}))
    for platform in sorted({r["platform"] for r in rows if r["series"] == "firedac"}):
        out.append(f"\n## {titles.get(platform, platform)}: .NET and FireDAC in the same runs\n\n"
                   "FireDAC = default options (with `UpdateOptions.LockWait = True` and statements prepared in a transaction of "
                   "their own, see the README); ckDefault = the same with `FetchOptions.CursorKind := ckDefault` on the SELECT. "
                   "Factor = PostgreSQL against Firebird with the same client stack.\n\n"
                   "| Test | Unit | Firebird .NET | Firebird FireDAC | Firebird ckDefault | PostgreSQL .NET | PostgreSQL FireDAC | "
                   "PostgreSQL ckDefault | Factor .NET | Factor FireDAC | Factor ckDefault | n |\n"
                   "| --- | --- |" + " ---: |" * 10 + "\n")
        for test, params, label, unit in COMPARE:
            cells = {}
            for e in ("fb", "pg"):
                for i, (driver, cursor) in enumerate(variants):
                    if test != "oltp":  # only the SELECT of the pgbench scripts has a cursor
                        cells[(e, i)] = get(platform, test, e, params, "firedac", driver) if i < 2 else None
                    else:
                        cells[(e, i)] = get(platform, test, e, {**params, **(cursor or {"cursor": ""})}, "firedac", driver)
            if not any(cells[(e, 1)] for e in ("fb", "pg")):
                continue
            factors = [f"{cells[('pg', i)]['median'] / cells[('fb', i)]['median']:.1f}" if cells[("fb", i)] and cells[("pg", i)] else ""
                       for i in range(3)]
            n = "/".join(str(cells[(e, i)]["n"]) if cells[(e, i)] else "-" for e in ("fb", "pg") for i in range(3))
            out.append(f"| {label} | {unit} | " + " | ".join(fmt(cells[(e, i)]["median"]) if cells[(e, i)] else ""
                                                       for e in ("fb", "pg") for i in range(3)) +
                       " | " + " | ".join(factors) + f" | {n} |\n")
    return "".join(out)


if __name__ == "__main__":
    main()
