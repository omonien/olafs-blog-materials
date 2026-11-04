#!/usr/bin/env python3
"""Draws the charts of the post "Firebird vs PostgreSQL" as self-contained SVG files, in German and English.

Reads the medians from results/medians.json (written by tools/summarize.py). Every SVG carries its own background
and switches between a light and a dark variant with prefers-color-scheme, so it reads on both themes of the site
when embedded with <img>. Usage: python3 charts/make_charts.py [out-dir]
"""
import json
import math
import sys
from pathlib import Path
from xml.sax.saxutils import escape

HERE = Path(__file__).resolve().parent
WIDTH = 760
FONT = "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"

# Light and dark tokens. Series: Firebird orange, PostgreSQL blue (slots 2 and 1 of the dataviz reference palette),
# validated with validate_palette.js against both surfaces.
THEME = {
    "light": {"surface": "#ffffff", "ink": "#020617", "ink2": "#475569", "muted": "#64748b",
              "grid": "#e2e8f0", "base": "#cbd5e1", "border": "#e2e8f0", "fb": "#eb6834", "pg": "#2a78d6"},
    "dark": {"surface": "#0f1620", "ink": "#ffffff", "ink2": "#cbd5e1", "muted": "#94a3b8",
             "grid": "#1f2937", "base": "#334155", "border": "#1f2937", "fb": "#d95926", "pg": "#3987e5"},
}

TEXT = {
    "de": {
        "dec": ",", "thousands": ".",
        "fb": "Firebird 5.0.4", "pg": "PostgreSQL 18",
        "mac": "macOS, beide Server in Docker auf denselben vier CPUs",
        "windows": "Windows 11 (VM), beide Server lokal ohne Netz",
        "factor": "PostgreSQL × {0}", "factor_inv": "Firebird × {0}",
        "na": "nicht möglich",
        "read_title": "Zwei Millionen Zeilen lesen",
        "read_sub": "Tausend Zeilen pro Sekunde, Median aller Durchläufe. Mehr ist besser.",
        "read_groups": {"on": "12 Spalten, wie im ersten Beitrag", "wire": "Firebird mit Leitungsverschlüsselung"},
        "read_note": "PostgreSQL lief ohne TLS; die Verschlüsselung wurde nur bei Firebird gemessen.",
        "insert_title": "Eine Zeile je Transaktion",
        "insert_sub": "Transaktionen pro Sekunde, Median. Mehr ist besser.",
        "insert_groups": {("default", "1"): "dauerhaft, 1 Client", ("default", "8"): "dauerhaft, 8 Clients",
                          ("relaxed", "1"): "gelockert, 1 Client", ("relaxed", "8"): "gelockert, 8 Clients"},
        "insert_note": "Dauerhaft: Forced Writes an, synchronous_commit an. Gelockert: Forced Writes aus, synchronous_commit aus.",
        "bulk_title": "Massenladen in einer Transaktion",
        "bulk_sub": "Tausend Zeilen pro Sekunde, Median. Mehr ist besser.",
        "bulk_groups": {"prepared": "Prepared INSERT, Zeile für Zeile", "native": "Batch-API (Firebird), COPY (PostgreSQL)"},
        "oltp_title": "Gleichzeitige Clients, pgbench-Skripte",
        "oltp_sub": "Transaktionen pro Sekunde je Anzahl der Clients, Median. Mehr ist besser.",
        "oltp_scripts": {"select": "nur lesen (-S)", "simple": "einfaches Update (-N)", "tpcb": "TPC-B-ähnlich"},
        "oltp_clients": "Clients",
        "json_title": "JSON-Abfragen über 500.000 Dokumente",
        "json_sub": "Millisekunden, Median aus fünf Läufen, logarithmische Achse. Weniger ist besser.",
        "json_rows": {"lookup-index": "Kunde suchen: JSON-Index (GIN)", "lookup-scan": "Kunde suchen: SQL/JSON, ohne Index",
                      "lookup-like": "Kunde suchen: Textsuche mit LIKE", "lookup-client": "Kunde suchen: im Client parsen",
                      "agg-sql": "Summe je Status: SQL/JSON", "agg-sql-serial": "Summe je Status: SQL/JSON, ohne Parallelität",
                      "agg-client": "Summe je Status: im Client parsen"},
        "json_note": "Firebird 5 kennt keine JSON-Funktionen. LIKE trifft hier nur, weil alle Dokumente gleich formatiert sind.",
        "ms": "{0} ms",
        "raw": "Rohdaten und Last: results/",
    },
    "en": {
        "dec": ".", "thousands": ",",
        "fb": "Firebird 5.0.4", "pg": "PostgreSQL 18",
        "mac": "macOS, both servers in Docker on the same four CPUs",
        "windows": "Windows 11 (VM), both servers local without network",
        "factor": "PostgreSQL × {0}", "factor_inv": "Firebird × {0}",
        "na": "not possible",
        "read_title": "Reading two million rows",
        "read_sub": "Thousand rows per second, median of all passes. Higher is better.",
        "read_groups": {"on": "12 columns, as in the first post", "wire": "Firebird with wire encryption"},
        "read_note": "PostgreSQL ran without TLS; encryption was measured for Firebird only.",
        "insert_title": "One row per transaction",
        "insert_sub": "Transactions per second, median. Higher is better.",
        "insert_groups": {("default", "1"): "durable, 1 client", ("default", "8"): "durable, 8 clients",
                          ("relaxed", "1"): "relaxed, 1 client", ("relaxed", "8"): "relaxed, 8 clients"},
        "insert_note": "Durable: forced writes on, synchronous_commit on. Relaxed: forced writes off, synchronous_commit off.",
        "bulk_title": "Bulk load in one transaction",
        "bulk_sub": "Thousand rows per second, median. Higher is better.",
        "bulk_groups": {"prepared": "prepared INSERT, row by row", "native": "batch API (Firebird), COPY (PostgreSQL)"},
        "oltp_title": "Concurrent clients, pgbench scripts",
        "oltp_sub": "Transactions per second by number of clients, median. Higher is better.",
        "oltp_scripts": {"select": "read only (-S)", "simple": "simple update (-N)", "tpcb": "TPC-B like"},
        "oltp_clients": "clients",
        "json_title": "JSON queries over 500,000 documents",
        "json_sub": "Milliseconds, median of five runs, logarithmic axis. Lower is better.",
        "json_rows": {"lookup-index": "find a customer: JSON index (GIN)", "lookup-scan": "find a customer: SQL/JSON, no index",
                      "lookup-like": "find a customer: text search with LIKE", "lookup-client": "find a customer: parse in the client",
                      "agg-sql": "sum per status: SQL/JSON", "agg-sql-serial": "sum per status: SQL/JSON, no parallelism",
                      "agg-client": "sum per status: parse in the client"},
        "json_note": "Firebird 5 has no JSON functions. LIKE only hits here because all documents are formatted alike.",
        "ms": "{0} ms",
        "raw": "Raw data and load: results/",
    },
}
PLATFORMS = ["mac", "windows"]


def load(path):
    rows = json.loads(path.read_text(encoding="utf-8"))

    def get(platform, test, engine, **params):
        for r in rows:
            if r["platform"] == platform and r["test"] == test and r["engine"] == engine and \
                    all(r["params"].get(k) == v for k, v in params.items()):
                return r["median"]
        return None
    return get


def number(value, lang, digits=0):
    t = TEXT[lang]
    s = f"{value:,.{digits}f}"
    return s.replace(",", "\x00").replace(".", t["dec"]).replace("\x00", t["thousands"])


def short(value, lang):
    """Two significant digits at most, enough for a bar label."""
    if value == 0:
        return "0"
    if value >= 100:
        return number(round(value), lang)
    if value >= 10:
        return number(value, lang, 1 if value < 20 else 0)
    return number(value, lang, 1)


def text_width(s, size):
    narrow = sum(1 for c in s if c in "il.,:;|!'() ")
    wide = sum(1 for c in s if c in "MWmw%")
    return size * (0.56 * (len(s) - narrow - wide) + 0.3 * narrow + 0.85 * wide)


def bar(x, y, w, h, cls, r=4):
    """Horizontal bar, square at the baseline, rounded at its data end."""
    if w <= 0:
        return ""
    r = min(r, w, h / 2)
    return (f'<path class="{cls}" d="M{x:.1f},{y:.1f}h{w - r:.1f}a{r},{r} 0 0 1 {r},{r}'
            f'v{h - 2 * r:.1f}a{r},{r} 0 0 1 -{r},{r}h-{w - r:.1f}z"/>')


def style():
    def rules(c):
        return (f".bg{{fill:{c['surface']};stroke:{c['border']}}}.t1{{fill:{c['ink']}}}.t2{{fill:{c['ink2']}}}"
                f".t3{{fill:{c['muted']}}}.grid{{stroke:{c['grid']}}}.base{{stroke:{c['base']}}}"
                f".fb{{fill:{c['fb']}}}.pg{{fill:{c['pg']}}}.fbl{{stroke:{c['fb']}}}.pgl{{stroke:{c['pg']}}}"
                f".ring{{stroke:{c['surface']}}}")
    return (f"<style>text{{font-family:{FONT}}}{rules(THEME['light'])}"
            f"@media (prefers-color-scheme: dark){{{rules(THEME['dark'])}}}</style>")


def svg(height, title, desc, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {height}" width="{WIDTH}" '
            f'height="{height}" role="img" aria-labelledby="t d"><title id="t">{escape(title)}</title>'
            f'<desc id="d">{escape(desc)}</desc>{style()}'
            f'<rect class="bg" x="0.5" y="0.5" width="{WIDTH - 1}" height="{height - 1}" rx="12"/>{body}</svg>\n')


def txt(x, y, s, cls="t1", size=13, weight=None, anchor=None):
    extra = (f' font-weight="{weight}"' if weight else "") + (f' text-anchor="{anchor}"' if anchor else "")
    return f'<text class="{cls}" x="{x:.1f}" y="{y:.1f}" font-size="{size}"{extra}>{escape(s)}</text>'


def header(lang, title, subtitle):
    t = TEXT[lang]
    out = [txt(24, 36, title, size=18, weight="600"), txt(24, 58, subtitle, "t2")]
    x, y = 24, 72
    for cls in ("fb", "pg"):
        out.append(f'<rect class="{cls}" x="{x}" y="{y + 6}" width="12" height="12" rx="3"/>')
        out.append(txt(x + 18, y + 16.5, t[cls], "t2"))
        x += 18 + text_width(t[cls], 13) + 24
    return "".join(out), y + 38


def nice_ticks(top):
    """Round tick values from 0 to at least top."""
    raw = top / 5
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw)
    n = math.ceil(top / step)
    return [i * step for i in range(n + 1)]


def pairs(lang, title, subtitle, panels, scale_div, note, label_col=210):
    """Grouped horizontal bars: per panel and group one Firebird and one PostgreSQL bar, with the factor."""
    t = TEXT[lang]
    head, y = header(lang, title, subtitle)
    values = [v / scale_div for _, groups in panels for _, fb, pg in groups for v in (fb, pg) if v]
    if not values:
        return svg(y + 20, title, "no data yet", head)
    ticks = nice_ticks(max(values) * 1.02)
    x0, plot = label_col, WIDTH - label_col - 70
    scale = plot / ticks[-1]
    out = [head]
    bar_h, pair_gap, group_gap = 14, 2, 16
    desc = []
    for panel, groups in panels:
        groups = [g for g in groups if g[1] or g[2]]
        if not groups:
            continue
        y += 8
        out.append(txt(24, y, t[panel], "t1", 13, "600"))
        y += 12
        top = y
        bottom = y + len(groups) * (2 * bar_h + pair_gap + group_gap) - group_gap + 4
        for v in ticks:
            x = x0 + v * scale
            out.append(f'<line class="grid" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{bottom}" stroke-width="1"/>')
            out.append(txt(x, bottom + 16, number(v, lang, 0 if v == int(v) else 1), "t3", 12, anchor="middle"))
        gy = y + 4
        for label, fb, pg in groups:
            out.append(txt(24, gy + bar_h - 1, label, "t1"))
            if fb and pg and pg is not False:
                f = pg / fb
                factor = t["factor"].format(number(f, lang, 1)) if f >= 1 else t["factor_inv"].format(number(1 / f, lang, 1))
                out.append(txt(24, gy + 2 * bar_h + pair_gap - 1, factor, "t3", 12))
            for i, (cls, value) in enumerate((("fb", fb), ("pg", pg))):
                by = gy + i * (bar_h + pair_gap)
                if value is False:  # not measured for this server
                    continue
                if value is None:
                    out.append(txt(x0 + 6, by + bar_h - 2.5, t["na"], "t3", 12))
                    continue
                w = value / scale_div * scale
                out.append(bar(x0, by, w, bar_h, cls))
                out.append(txt(x0 + w + 6, by + bar_h - 2.5, short(value / scale_div, lang), "t2", 12))
            desc.append(f"{t[panel]}, {label}: Firebird {fb}, PostgreSQL {pg}")
            gy += 2 * bar_h + pair_gap + group_gap
        out.append(f'<line class="base" x1="{x0}" y1="{top}" x2="{x0}" y2="{bottom}" stroke-width="1"/>')
        y = bottom + 30
    for line in note:
        out.append(txt(24, y, line, "t3", 12))
        y += 18
    return svg(y + 6, title, "; ".join(desc), "".join(out))


def read_chart(get, lang):
    t = TEXT[lang]
    panels = [(p, [(t["read_groups"]["on"], get(p, "read", "fb", zoned="on", wirecrypt="off"), get(p, "read", "pg", zoned="on", wirecrypt="off"))])
              for p in PLATFORMS]
    for p, groups in panels:
        wire = get(p, "read", "fb", zoned="on", wirecrypt="on")
        if wire:
            groups.append((t["read_groups"]["wire"], wire, False))
    return pairs(lang, t["read_title"], t["read_sub"], panels, 1000, [t["read_note"], t["raw"]], label_col=300)


def insert_chart(get, lang):
    t = TEXT[lang]
    panels = [(p, [(label, get(p, "insert", "fb", durability=d, clients=c), get(p, "insert", "pg", durability=d, clients=c))
                   for (d, c), label in t["insert_groups"].items()]) for p in PLATFORMS]
    return pairs(lang, t["insert_title"], t["insert_sub"], panels, 1, [t["insert_note"], t["raw"]])


def bulk_chart(get, lang):
    t = TEXT[lang]
    panels = [(p, [(label, get(p, "bulk", "fb", mode=m), get(p, "bulk", "pg", mode=m)) for m, label in t["bulk_groups"].items()])
              for p in PLATFORMS]
    return pairs(lang, t["bulk_title"], t["bulk_sub"], panels, 1000, [t["raw"]], label_col=320)


def oltp_chart(get, lang):
    """Small multiples: a column per script, a row per platform, one line per server over the client counts."""
    t = TEXT[lang]
    head, y = header(lang, t["oltp_title"], t["oltp_sub"])
    out = [head]
    scripts = list(t["oltp_scripts"])
    clients = ["1", "4", "16", "64"]
    col_w, gap = (WIDTH - 48 - 2 * 24) / 3, 24
    cell_h = 150
    desc = []
    for script_i, script in enumerate(scripts):
        cx = 24 + script_i * (col_w + gap)
        out.append(txt(cx, y + 4, t["oltp_scripts"][script], "t1", 13, "600"))
    y += 14
    # One y scale per panel: what counts is Firebird against PostgreSQL on one platform, not the platforms.
    for p in PLATFORMS:
        out.append(txt(24, y + 14, t[p], "t2", 12))
        top_y = y + 26
        bottom_y = top_y + cell_h - 30
        for script_i, script in enumerate(scripts):
            cx = 24 + script_i * (col_w + gap)
            plot_x0, plot_x1 = cx + 40, cx + col_w - 10
            present = [c for c in clients if get(p, "oltp", "fb", script=script, clients=c) or get(p, "oltp", "pg", script=script, clients=c)]
            top = max((get(p, "oltp", e, script=script, clients=c) or 0) for e in ("fb", "pg") for c in present) if present else 0
            if not top:
                continue
            ticks = nice_ticks(top * 1.05)
            ys = lambda v: bottom_y - v / ticks[-1] * (bottom_y - top_y)
            xs = {c: plot_x0 + i * (plot_x1 - plot_x0) / max(len(present) - 1, 1) for i, c in enumerate(present)}
            for v in ticks[::max(1, len(ticks) // 3)]:
                out.append(f'<line class="grid" x1="{plot_x0}" y1="{ys(v):.1f}" x2="{plot_x1}" y2="{ys(v):.1f}" stroke-width="1"/>')
                out.append(txt(plot_x0 - 6, ys(v) + 4, short(v, lang) if v < 1000 else number(v / 1000, lang, 0) + (" Tsd." if lang == "de" else "k"),
                               "t3", 11, anchor="end"))
            out.append(f'<line class="base" x1="{plot_x0}" y1="{bottom_y}" x2="{plot_x1}" y2="{bottom_y}" stroke-width="1"/>')
            for c in present:
                out.append(txt(xs[c], bottom_y + 15, c, "t3", 11, anchor="middle"))
            for engine, line_cls, dot_cls in (("fb", "fbl", "fb"), ("pg", "pgl", "pg")):
                pts = [(xs[c], ys(v), v) for c in present if (v := get(p, "oltp", engine, script=script, clients=c))]
                if len(pts) > 1:
                    d = " ".join(f"{'M' if i == 0 else 'L'}{x:.1f},{yv:.1f}" for i, (x, yv, _) in enumerate(pts))
                    out.append(f'<path class="{line_cls}" d="{d}" fill="none" stroke-width="2"/>')
                for x, yv, _ in pts:
                    out.append(f'<circle class="{dot_cls} ring" cx="{x:.1f}" cy="{yv:.1f}" r="4" stroke-width="2"/>')
                if pts:
                    x, yv, v = pts[-1]
                    other = [get(p, "oltp", e2, script=script, clients=present[-1]) for e2 in ("fb", "pg") if e2 != engine][0]
                    below = engine == "fb" and other is not None and abs(ys(other) - yv) < 16
                    out.append(txt(x + 2, yv + 16 if below else yv - 8, short(v, lang), "t2", 11, anchor="end"))
                desc.append(f"{t[p]}, {t['oltp_scripts'][script]}, {t[engine]}: " +
                            ", ".join(f"{c} {t['oltp_clients']} {get(p, 'oltp', engine, script=script, clients=c)}" for c in present))
        y = bottom_y + 26
    out.append(txt(24, y + 4, f"{t['oltp_clients']}: 1, 4, 16, 64 (64 nur TPC-B). Jedes Feld hat eine eigene Skala." if lang == "de" else f"{t['oltp_clients'].capitalize()}: 1, 4, 16, 64 (64 for TPC-B only). Every panel has its own scale.", "t3", 12))
    out.append(txt(24, y + 22, t["raw"], "t3", 12))
    return svg(y + 36, t["oltp_title"], "; ".join(desc), "".join(out))


def json_chart(get, lang):
    """Horizontal bars on a log axis; a missing bar says the method does not exist for that server."""
    t = TEXT[lang]
    head, y = header(lang, t["json_title"], t["json_sub"])
    out = [head]
    rows = [("lookup-index", {}), ("lookup-scan", {}), ("lookup-like", {}), ("lookup-client", {}),
            ("agg-sql", {"parallel": "on"}), ("agg-sql-serial", {"parallel": "off"}), ("agg-client", {})]
    x0, plot = 300, WIDTH - 300 - 60
    values = [v for p in PLATFORMS for key, extra in rows for e in ("fb", "pg")
              if (v := get(p, "json", e, query="agg-sql" if key == "agg-sql-serial" else key, parallel=extra.get("parallel", "on")))]
    lo, hi = 1, 10 ** math.ceil(math.log10(max(values + [10])))
    scale = lambda v: x0 + (math.log10(max(v, lo)) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * plot
    bar_h, pair_gap, group_gap = 12, 2, 12
    desc = []
    for p in PLATFORMS:
        y += 8
        out.append(txt(24, y, t[p], "t1", 13, "600"))
        y += 12
        top = y
        bottom = y + len(rows) * (2 * bar_h + pair_gap + group_gap) - group_gap + 4
        for v in (10 ** i for i in range(int(math.log10(hi)) + 1)):
            x = scale(v)
            out.append(f'<line class="grid" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{bottom}" stroke-width="1"/>')
            out.append(txt(x, bottom + 16, number(v, lang), "t3", 12, anchor="middle"))
        gy = y + 4
        for key, extra in rows:
            query = "agg-sql" if key == "agg-sql-serial" else key
            params = {"query": query, **({"parallel": extra.get("parallel", "on")})}
            out.append(txt(24, gy + bar_h + 1, t["json_rows"][key], "t1", 12))
            for i, (cls, engine) in enumerate((("fb", "fb"), ("pg", "pg"))):
                by = gy + i * (bar_h + pair_gap)
                v = get(p, "json", engine, **params)
                if v is None:
                    if engine == "fb":
                        out.append(txt(x0 + 6, by + bar_h - 2, t["na"], "t3", 11))
                    continue
                w = scale(v) - x0
                out.append(bar(x0, by, w, bar_h, cls))
                out.append(txt(x0 + w + 6, by + bar_h - 2, t["ms"].format(short(v, lang)), "t2", 11))
                desc.append(f"{t[p]}, {t['json_rows'][key]}, {t[engine]}: {v} ms")
            gy += 2 * bar_h + pair_gap + group_gap
        out.append(f'<line class="base" x1="{x0}" y1="{top}" x2="{x0}" y2="{bottom}" stroke-width="1"/>')
        y = bottom + 30
    out.append(txt(24, y, t["json_note"], "t3", 12))
    out.append(txt(24, y + 18, t["raw"], "t3", 12))
    return svg(y + 30, t["json_title"], "; ".join(desc), "".join(out))


def main():
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE
    get = load(HERE.parent / "results" / "medians.json")
    for lang in TEXT:
        for name, draw in (("read", read_chart), ("insert", insert_chart), ("bulk", bulk_chart),
                           ("oltp", oltp_chart), ("json", json_chart)):
            (out_dir / f"{name}-{lang}.svg").write_text(draw(get, lang), encoding="utf-8")
    print(f"wrote 10 charts to {out_dir}")


if __name__ == "__main__":
    main()
