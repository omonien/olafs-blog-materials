#!/usr/bin/env python3
"""Draws the four charts of the blog post as self-contained SVG files, in German and English.

The numbers are the medians and sums from results/2026-11-03-runs.md. Every SVG carries its own
background and switches between a light and a dark variant with prefers-color-scheme, so it reads
on both themes of the site when embedded with <img>. Usage: python3 make_charts.py [out-dir]
"""
import sys
from pathlib import Path
from xml.sax.saxutils import escape

WIDTH = 760
FONT = "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"

# Light and dark tokens; series colors validated with the dataviz palette checks for both surfaces.
THEME = {
    "light": {"mode": "light", "surface": "#ffffff", "ink": "#020617", "ink2": "#475569", "muted": "#64748b",
              "grid": "#e2e8f0", "base": "#cbd5e1", "border": "#e2e8f0",
              "firedac": "#ee2722", "dotnet": "#0097a7", "client": "#2a78d6", "system": "#6250d6",
              "wait": "#eda100", "other": "#9aa3af", "quiet": "#b6bdc7"},
    "dark": {"mode": "dark", "surface": "#0f1620", "ink": "#ffffff", "ink2": "#cbd5e1", "muted": "#94a3b8",
             "grid": "#1f2937", "base": "#334155", "border": "#1f2937",
             "firedac": "#fa423c", "dotnet": "#0097a7", "client": "#3987e5", "system": "#9085e9",
             "wait": "#c98500", "other": "#5b6472", "quiet": "#465061"},
}
# Text set inside a filled segment: white, near-black on yellow, and on the light gray only in light mode.
INSIDE_INK = {"light": {"in": "#ffffff", "in-wait": "#0b0b0b", "in-other": "#0b0b0b"},
              "dark": {"in": "#ffffff", "in-wait": "#0b0b0b", "in-other": "#ffffff"}}

TEXT = {
    "de": {
        "dec": ",", "thousands": ".",
        "firedac": "FireDAC (Delphi 13.1)",
        "dotnet": ".NET 9 (FirebirdClient, Npgsql, SqlClient)",
        "throughput_title": "Zwei Millionen Zeilen lesen",
        "throughput_sub": "Tausend Zeilen pro Sekunde, Median aus drei Durchläufen. Mehr ist besser.",
        "panel_mac": "macOS, Datenbank lokal in Docker, ohne Zeitzonenspalte",
        "panel_win": "Windows 11 (VM), Datenbank lokal ohne Netz, mit Zeitzonenspalte",
        "panel_net": "Windows 11 (VM), Datenbank über Tailscale, mit Zeitzonenspalte",
        "factor": "Faktor {0}",
        "throughput_note": "PostgreSQL und SQL Server unter macOS bei hoher Last gemessen. Rohdaten: results/2026-11-03-runs.md",
        "cpu_title": "Client-CPU je gelesener Zeile, Windows lokal",
        "cpu_sub": "Mikrosekunden, über ganze Programmläufe mit 6 Millionen Zeilen. Weniger ist besser.",
        "cpu_fb_tz": "Firebird, mit Zeitzone", "cpu_fb": "Firebird, ohne Zeitzone", "cpu_pg": "PostgreSQL",
        "cpu_limit": "Firebird-Server: 6,0 µs je Zeile",
        "cpu_note": "Schneller als der Server liefert, kann kein Treiber lesen. .NET erreicht diese Grenze bei Firebird bereits.",
        "us": "{0} µs",
        "micro_title": "Einen UTF-8-String dekodieren, macOS",
        "micro_sub": "Nanosekunden je Aufruf, 38 Byte, 6 Millionen Aufrufe. Weniger ist besser.",
        "micro_rows": ["UnicodeFromLocaleChars (RTL)", "Utf8ToUnicode (RTL)", "TEncoding.UTF8.GetString (RTL)",
                       "iconv, Konverter wiederverwendet", "Fix-Vorschlag"],
        "micro_ref": "Windows-RTL: 57 ns",
        "micro_note": "Unter Windows braucht der Fix 59 ns, die RTL 57 ns. macOS-Last während der Messung: etwa 10.",
        "ns": "{0} ns",
        "profile_title": "Wohin die Zeit von FireDAC geht, Windows lokal",
        "profile_sub": "Anteil der Stichproben des lesenden Threads, Wanduhr einschließlich Warten.",
        "profile_rows": ["Firebird", "PostgreSQL"],
        "profile_parts": ["Client-Bibliothek (fbclient, libpq)", "FireDAC, RTL, Testschleife",
                          "Windows-Systemcode", "Warten auf Daten", "Sonstiges (ICU, C-Laufzeit)"],
        "profile_note": "Firebird: 2.621 Stichproben, PostgreSQL: 2.818, je 15 Sekunden, mit tools/sample-windows.ps1.",
    },
    "en": {
        "dec": ".", "thousands": ",",
        "firedac": "FireDAC (Delphi 13.1)",
        "dotnet": ".NET 9 (FirebirdClient, Npgsql, SqlClient)",
        "throughput_title": "Reading two million rows",
        "throughput_sub": "Thousand rows per second, median of three passes. Higher is better.",
        "panel_mac": "macOS, database local in Docker, without the time zone column",
        "panel_win": "Windows 11 (VM), database local without network, with the time zone column",
        "panel_net": "Windows 11 (VM), database over Tailscale, with the time zone column",
        "factor": "factor {0}",
        "throughput_note": "PostgreSQL and SQL Server on macOS measured under high load. Raw data: results/2026-11-03-runs.md",
        "cpu_title": "Client CPU per row read, Windows local",
        "cpu_sub": "Microseconds, over whole program runs with 6 million rows. Lower is better.",
        "cpu_fb_tz": "Firebird, with time zone", "cpu_fb": "Firebird, without time zone", "cpu_pg": "PostgreSQL",
        "cpu_limit": "Firebird server: 6.0 µs per row",
        "cpu_note": "No driver reads faster than the server delivers. With Firebird, .NET already reaches that limit.",
        "us": "{0} µs",
        "micro_title": "Decoding one UTF-8 string, macOS",
        "micro_sub": "Nanoseconds per call, 38 bytes, 6 million calls. Lower is better.",
        "micro_rows": ["UnicodeFromLocaleChars (RTL)", "Utf8ToUnicode (RTL)", "TEncoding.UTF8.GetString (RTL)",
                       "iconv, converter reused", "Proposed fix"],
        "micro_ref": "Windows RTL: 57 ns",
        "micro_note": "On Windows the fix takes 59 ns, the RTL 57 ns. macOS load average during the run: about 10.",
        "ns": "{0} ns",
        "profile_title": "Where FireDAC spends its time, Windows local",
        "profile_sub": "Share of the stack samples of the reading thread, wall clock including waits.",
        "profile_rows": ["Firebird", "PostgreSQL"],
        "profile_parts": ["Client library (fbclient, libpq)", "FireDAC, RTL, benchmark loop",
                          "Windows system code", "Waiting for data", "Other (ICU, C runtime)"],
        "profile_note": "Firebird: 2,621 samples, PostgreSQL: 2,818, 15 seconds each, with tools/sample-windows.ps1.",
    },
}

# Medians of the three passes, rows per second (results/2026-11-03-runs.md).
THROUGHPUT = [
    ("panel_mac", [("Firebird", 66019, 200239), ("PostgreSQL", 63507, 373683), ("SQL Server", 54373, 168859)]),
    ("panel_win", [("Firebird", 93618, 167961), ("PostgreSQL", 173104, 571769)]),
    ("panel_net", [("Firebird", 47147, 52084), ("PostgreSQL", 30499, 47197), ("SQL Server", 18844, 58932)]),
]
# Client CPU seconds of one program run (6 million rows) on Windows local.
CPU = [("cpu_fb_tz", 63.7, 26.0), ("cpu_fb", 49.4, 24.8), ("cpu_pg", 27.2, 6.7)]
CPU_FIREBIRD_SERVER = 35.7  # server CPU seconds while .NET read the same 6 million rows
MICRO_MAC = [1787, 2228, 4844, 1016, 122]
MICRO_WINDOWS_RTL = 57
# Self time by module, grouped: client library, program, Windows system code, waiting, other.
PROFILE = [[41.5, 37.4, 9.9, 3.8, 7.3], [1.9, 75.9, 7.6, 14.2, 0.3]]
PROFILE_KEYS = ["client", "firedac", "system", "wait", "other"]


def number(value, lang, digits=0):
    """Formats a number with the decimal and thousands separators of the language."""
    t = TEXT[lang]
    s = f"{value:,.{digits}f}"
    return s.replace(",", "\x00").replace(".", t["dec"]).replace("\x00", t["thousands"])


def text_width(s, size):
    """Rough width of a sans-serif string; enough to keep labels off each other."""
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
    """CSS for both themes; the dark block applies when the viewer's system is dark."""
    def rules(c):
        fills = "".join(f".{k}{{fill:{c[k]}}}" for k in
                        ("firedac", "dotnet", "client", "system", "wait", "other", "quiet"))
        inks = "".join(f".{k}{{fill:{v}}}" for k, v in INSIDE_INK[c["mode"]].items())
        return (f"{inks}.bg{{fill:{c['surface']};stroke:{c['border']}}}.t1{{fill:{c['ink']}}}.t2{{fill:{c['ink2']}}}"
                f".t3{{fill:{c['muted']}}}.grid{{stroke:{c['grid']}}}.base{{stroke:{c['base']}}}"
                f".ref{{stroke:{c['ink2']}}}.gap{{stroke:{c['surface']}}}{fills}")
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


def header(lang, title, subtitle, legend):
    """Title, subtitle and an optional legend row; returns the SVG and the next free y."""
    out = [txt(24, 36, title, size=18, weight="600"), txt(24, 58, subtitle, "t2")]
    y = 72
    if legend:
        x = 24
        for cls, label in legend:
            out.append(f'<rect class="{cls}" x="{x}" y="{y + 6}" width="12" height="12" rx="3"/>')
            out.append(txt(x + 18, y + 16.5, label, "t2"))
            x += 18 + text_width(label, 13) + 24
        y += 30
    return "".join(out), y + 8


def ticks(x0, scale, y_top, y_bottom, values, label):
    out = []
    for v in values:
        x = x0 + v * scale
        out.append(f'<line class="grid" x1="{x:.1f}" y1="{y_top}" x2="{x:.1f}" y2="{y_bottom}" stroke-width="1"/>')
        out.append(txt(x, y_bottom + 16, label(v), "t3", 12, anchor="middle"))
    return "".join(out)


def throughput(lang):
    t = TEXT[lang]
    head, y = header(lang, t["throughput_title"], t["throughput_sub"],
                     [("firedac", t["firedac"]), ("dotnet", t["dotnet"])])
    x0, plot = 170, WIDTH - 170 - 72
    scale = plot / 600000
    out = [head]
    bar_h, pair_gap, group_gap = 14, 2, 16
    for key, groups in THROUGHPUT:
        y += 14
        out.append(txt(24, y, t[key], "t1", 13, "600"))
        y += 12
        top = y
        bottom = y + len(groups) * (2 * bar_h + pair_gap + group_gap) - group_gap + 4
        out.append(ticks(x0, scale, top, bottom, [0, 100000, 200000, 300000, 400000, 500000, 600000],
                         lambda v: number(v / 1000, lang)))
        gy = y + 4
        for name, fd, net in groups:
            out.append(txt(24, gy + bar_h - 1, name, "t1"))
            out.append(txt(24, gy + 2 * bar_h + pair_gap - 1, t["factor"].format(number(net / fd, lang, 1)), "t3", 12))
            for i, (cls, value) in enumerate((("firedac", fd), ("dotnet", net))):
                by = gy + i * (bar_h + pair_gap)
                w = value * scale
                out.append(bar(x0, by, w, bar_h, cls))
                out.append(txt(x0 + w + 6, by + bar_h - 2.5, number(round(value / 1000), lang), "t2", 12))
            gy += 2 * bar_h + pair_gap + group_gap
        out.append(f'<line class="base" x1="{x0}" y1="{top}" x2="{x0}" y2="{bottom}" stroke-width="1"/>')
        y = bottom + 28
    out.append(txt(24, y + 10, t["throughput_note"], "t3", 12))
    height = y + 30
    desc = "; ".join(f"{t[key]}: " + ", ".join(f"{n} FireDAC {fd} / .NET {net}" for n, fd, net in g)
                     for key, g in THROUGHPUT)
    return svg(height, t["throughput_title"], desc, "".join(out))


def cpu(lang):
    t = TEXT[lang]
    head, y = header(lang, t["cpu_title"], t["cpu_sub"], [("firedac", t["firedac"]), ("dotnet", t["dotnet"])])
    x0, plot = 190, WIDTH - 190 - 80
    scale = plot / 12
    out = [head]
    bar_h, pair_gap, group_gap = 16, 2, 18
    top = y + 24
    rows_h = len(CPU) * (2 * bar_h + pair_gap + group_gap) - group_gap
    bottom = top + rows_h + 8
    out.append(ticks(x0, scale, top, bottom, [0, 2, 4, 6, 8, 10, 12], lambda v: number(v, lang)))
    fb_rows = 2 * (2 * bar_h + pair_gap + group_gap) - group_gap
    limit_x = x0 + CPU_FIREBIRD_SERVER / 6.0 * scale
    out.append(f'<line class="ref" x1="{limit_x:.1f}" y1="{top - 16}" x2="{limit_x:.1f}" y2="{top + 4 + fb_rows + 2}" stroke-width="1.5"/>')
    out.append(txt(limit_x + 6, top - 6, t["cpu_limit"], "t2", 12))
    gy = top + 4
    for key, fd, net in CPU:
        out.append(txt(24, gy + bar_h + 5, t[key], "t1"))
        for i, (cls, seconds) in enumerate((("firedac", fd), ("dotnet", net))):
            per_row = seconds / 6.0
            by = gy + i * (bar_h + pair_gap)
            w = per_row * scale
            out.append(bar(x0, by, w, bar_h, cls))
            out.append(txt(x0 + w + 6, by + bar_h - 3.5, t["us"].format(number(per_row, lang, 1)), "t2", 12))
        gy += 2 * bar_h + pair_gap + group_gap
    out.append(f'<line class="base" x1="{x0}" y1="{top}" x2="{x0}" y2="{bottom}" stroke-width="1"/>')
    y = bottom + 46
    out.append(txt(24, y, t["cpu_note"], "t3", 12))
    desc = "; ".join(f"{t[k]}: FireDAC {fd / 6:.1f} µs, .NET {net / 6:.1f} µs" for k, fd, net in CPU)
    return svg(y + 20, t["cpu_title"], desc, "".join(out))


def micro(lang):
    t = TEXT[lang]
    head, y = header(lang, t["micro_title"], t["micro_sub"], None)
    x0, plot = 250, WIDTH - 250 - 70
    scale = plot / 5000
    out = [head]
    bar_h, gap = 18, 14
    top = y + 22
    bottom = top + len(MICRO_MAC) * (bar_h + gap) - gap + 8
    out.append(ticks(x0, scale, top, bottom, [0, 1000, 2000, 3000, 4000, 5000], lambda v: number(v, lang)))
    ref_x = x0 + MICRO_WINDOWS_RTL * scale
    out.append(f'<line class="ref" x1="{ref_x:.1f}" y1="{top - 14}" x2="{ref_x:.1f}" y2="{bottom}" stroke-width="1.5"/>')
    out.append(txt(ref_x + 6, top - 4, t["micro_ref"], "t2", 12))
    by = top + 4
    for i, (label, value) in enumerate(zip(t["micro_rows"], MICRO_MAC)):
        last = i == len(MICRO_MAC) - 1
        cls = "firedac" if last else "quiet"
        out.append(txt(24, by + bar_h - 4, label, "t1", 13, "600" if last else None))
        w = value * scale
        out.append(bar(x0, by, w, bar_h, cls))
        out.append(txt(x0 + w + 6, by + bar_h - 4, t["ns"].format(number(value, lang)), "t1" if last else "t2", 12,
                       "600" if last else None))
        by += bar_h + gap
    out.append(f'<line class="base" x1="{x0}" y1="{top}" x2="{x0}" y2="{bottom}" stroke-width="1"/>')
    y = bottom + 46
    out.append(txt(24, y, t["micro_note"], "t3", 12))
    desc = "; ".join(f"{label}: {value} ns" for label, value in zip(t["micro_rows"], MICRO_MAC)) + \
        f"; Windows RTL {MICRO_WINDOWS_RTL} ns"
    return svg(y + 20, t["micro_title"], desc, "".join(out))


def profile(lang):
    t = TEXT[lang]
    legend = list(zip(PROFILE_KEYS, t["profile_parts"]))
    head, y = header(lang, t["profile_title"], t["profile_sub"], None)
    out = [head]
    # The legend has five long entries: two rows.
    lx, ly = 24, y
    for i, (cls, label) in enumerate(legend):
        if i == 3:
            lx, ly = 24, ly + 22
        out.append(f'<rect class="{cls}" x="{lx}" y="{ly}" width="12" height="12" rx="3"/>')
        out.append(txt(lx + 18, ly + 10.5, label, "t2"))
        lx += 18 + text_width(label, 13) + 24
    y = ly + 36
    x0, plot = 130, WIDTH - 130 - 24
    bar_h = 24
    for name, parts in zip(t["profile_rows"], PROFILE):
        out.append(txt(24, y + bar_h - 7, name, "t1", 13, "600"))
        x = x0
        total = sum(parts)
        for i, (cls, share) in enumerate(zip(PROFILE_KEYS, parts)):
            w = share / total * plot
            first, last = i == 0, i == len(parts) - 1
            seg_w = max(w - (0 if last else 2), 0)  # 2px surface gap between segments
            if first:
                out.append(f'<rect class="{cls}" x="{x:.1f}" y="{y}" width="{seg_w:.1f}" height="{bar_h}"/>')
            elif last:
                out.append(bar(x, y, seg_w, bar_h, cls))
            else:
                out.append(f'<rect class="{cls}" x="{x:.1f}" y="{y}" width="{seg_w:.1f}" height="{bar_h}"/>')
            label = f"{number(share, lang, 0)} %"
            if seg_w > text_width(label, 12) + 12:
                ink = {"wait": "in-wait", "other": "in-other"}.get(cls, "in")
                out.append(txt(x + seg_w / 2, y + bar_h - 8, label, ink, 12, "600", "middle"))
            x += w
        y += bar_h + 22
    out.append(txt(24, y + 10, t["profile_note"], "t3", 12))
    desc = "; ".join(f"{name}: " + ", ".join(f"{p} {s} %" for p, s in zip(t["profile_parts"], parts))
                     for name, parts in zip(t["profile_rows"], PROFILE))
    return svg(y + 30, t["profile_title"], desc, "".join(out))


def main():
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent
    out_dir.mkdir(parents=True, exist_ok=True)
    for lang in TEXT:
        for name, draw in (("throughput", throughput), ("cpu-per-row", cpu), ("utf8-decode", micro),
                           ("firedac-profile", profile)):
            (out_dir / f"{name}-{lang}.svg").write_text(draw(lang), encoding="utf-8")
    print(f"wrote 8 charts to {out_dir}")


if __name__ == "__main__":
    main()
