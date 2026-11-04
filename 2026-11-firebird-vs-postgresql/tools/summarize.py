#!/usr/bin/env python3
"""Collects the RESULT lines of the raw logs into medians per platform, test, engine and parameters.

Every log line "RESULT key=value ..." is one measurement; the "LOAD ..." line before it records the load of the
Mac (and of the Docker VM or the Windows VM) at its start. Writes results/summary.md (tables with median, range,
number of runs and load) and results/medians.json (input of charts/make_charts.py).
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
    "oltp": ["script", "clients"], "json": ["query", "parallel"],
}
# The value a test is judged by; higher is better unless listed in LOWER.
METRIC = {"fill": "seconds", "json-setup": "load_s", "oltp-setup": "seconds", "size": "database_mb",
          "read": "rows_per_s", "insert": "tps", "bulk": "rows_per_s", "oltp": "tps", "json": "ms"}


def parse(line):
    return {m.group(1): m.group(3) if m.group(3) is not None else m.group(2) for m in PAIR.finditer(line)}


def records(results_dir):
    out = []
    for path in sorted((results_dir / "raw").glob("*.log")):
        platform = path.stem.split("-")[0]
        load = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("LOAD "):
                load = parse(line[5:])
            elif line.startswith("RESULT "):
                r = parse(line[7:])
                r["platform"] = platform
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
        key = (r["platform"], test, r["engine"]) + tuple(r.get(k, "") for k in KEYS.get(test, []))
        groups[key].append(r)
    rows = []
    for key, rs in sorted(groups.items()):
        platform, test, engine, *params = key
        metric = METRIC.get(test, "seconds")
        values = [number(r.get(metric)) for r in rs if number(r.get(metric)) is not None]
        if not values:
            continue
        row = {"platform": platform, "test": test, "engine": engine,
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


def table(rows, platform, test, columns):
    sel = [r for r in rows if r["platform"] == platform and r["test"] == test]
    if not sel:
        return ""
    head = "| " + " | ".join(c[0] for c in columns) + " |\n|" + "|".join(" --- " if i < 2 else " ---: " for i, _ in enumerate(columns)) + "|\n"
    body = "".join("| " + " | ".join(c[1](r) for c in columns) + " |\n" for r in sel)
    return f"### {platform}: {test}\n\n{head}{body}\n"


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
    params = lambda r: " ".join(f"{k}={v}" for k, v in r["params"].items())
    med = lambda d=0: (lambda r: f"{fmt(r['median'], d)} ({fmt(r['min'], d)} to {fmt(r['max'], d)}, n={r['n']})")
    cpu = lambda f: (lambda r: fmt(r.get(f), 1))
    lat = lambda f: (lambda r: fmt(r.get(f), 2))
    common = [("Engine", lambda r: r["engine"]), ("Parameters", params)]
    out = ["# Summary of the raw logs\n", "Generated by `tools/summarize.py` from `results/raw/*.log`. Median over all runs, range in brackets. "
           "CPU per unit: CPU time of the server processes (or of the client) divided by all rows or transactions of the run, warm-up included.\n"]
    for platform in sorted({r["platform"] for r in rows}):
        out.append(f"\n## {platform}\n")
        out.append(table(rows, platform, "read", common + [("Rows/s", med()), ("Server µs/row", cpu("server_us_per_unit")),
                                                            ("Client µs/row", cpu("client_us_per_unit")), ("Load", load_text)]))
        out.append(table(rows, platform, "insert", common + [("Transactions/s", med(1)), ("p50 ms", lat("p50_ms")), ("p99 ms", lat("p99_ms")),
                                                              ("Server µs/txn", cpu("server_us_per_unit")), ("Load", load_text)]))
        out.append(table(rows, platform, "bulk", common + [("Rows/s", med()), ("Commit s", lat("commit_s")),
                                                            ("Server µs/row", cpu("server_us_per_unit")), ("Client µs/row", cpu("client_us_per_unit")), ("Load", load_text)]))
        out.append(table(rows, platform, "oltp", common + [("Transactions/s", med(1)), ("p50 ms", lat("p50_ms")), ("p95 ms", lat("p95_ms")),
                                                            ("p99 ms", lat("p99_ms")), ("Retries", lambda r: fmt(r.get("retries"))),
                                                            ("Server µs/txn", cpu("server_us_per_unit")), ("Load", load_text)]))
        out.append(table(rows, platform, "json", common + [("Milliseconds", med(1)), ("Server CPU s", lambda r: fmt(r.get("server_cpu_s"), 2)),
                                                            ("Answer", lambda r: "<br>".join(r["answers"])), ("Load", load_text)]))
        for test in ("fill", "json-setup", "oltp-setup", "size"):
            out.append(table(rows, platform, test, common + [(METRIC[test], med(1)), ("Load", load_text)]))
    (results_dir / "summary.md").write_text("".join(out), encoding="utf-8")
    print(f"{len(rows)} groups -> {results_dir / 'summary.md'}, {results_dir / 'medians.json'}")


if __name__ == "__main__":
    main()
