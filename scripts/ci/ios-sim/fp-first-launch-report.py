import datetime
import re
import sys

LINE = re.compile(r"^\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d\.\d+)\S*\s+\S+\s+(.+?)\[(\d+):[0-9a-fx]+\]\s+(?:\[[^\]]*\]\s+)?FPX (\S+)(.*)$")
SYSTEM = [
    ("sync", "Syncing with LS"),
    ("no-provider", "No provider found with identifier chat.simplex.app.SimpleX-FP"),
    ("entitlement", "missing enumerate entitlement"),
    ("domain-created", "creating default domain for chat.simplex.app.SimpleX-FP"),
    ("extension-loaded", "Loaded extension chat.simplex.app.SimpleX-FP"),
    ("extension-launch", "Launching process with config: bundleID: chat.simplex.app.SimpleX-FP"),
]


def secs(ts):
    h, m, s = ts.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def code(error):
    m = re.match(r"([A-Za-z]+#-?\d+|timeout|none|unavailable)", error or "")
    return m.group(1) if m else (error or "")[:60]


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c).replace("|", "/") for c in row) + " |" for row in rows]
    return "\n".join(out)


def report(out, name):
    d = f"{out}/{name}"
    print(f"## Case {name}\n")
    try:
        print("```\n" + open(f"{d}/case.txt", errors="replace").read().strip() + "\n```\n")
        fpx = open(f"{d}/fpx.log", errors="replace").read().splitlines()
        system = open(f"{d}/system.log", errors="replace").read().splitlines()
    except OSError as e:
        print(f"missing: {e}\n")
        return
    events = []
    for raw in fpx:
        m = LINE.match(raw)
        if not m:
            continue
        ts, proc, pid, ev, rest = m.groups()
        f = dict(kv.split("=", 1) for kv in rest.split() if "=" in kv)
        f.update({"t": secs(ts), "ts": ts[:12], "proc": proc, "ev": ev})
        events.append(f)
    sysev = []
    for raw in system:
        for key, text in SYSTEM:
            if text in raw:
                proc = re.search(r"\s(\S+)\[(\d+):", raw)
                sysev.append({"t": secs(raw[11:23]), "ts": raw[11:23], "ev": key, "proc": f"{proc.group(1)}[{proc.group(2)}]" if proc else ""})
                break
    first_seen = {}
    for e in sysev:
        first_seen.setdefault(e["ev"], e)

    rows = []
    groups = {}
    for e in events:
        if e["ev"] == "attempt":
            k = (e.get("tag"), e.get("method"), code(e.get("error")), e.get("rootExists"))
            g = groups.get(k)
            if g:
                g[1] = e["ts"]
                g[2] += 1
            else:
                groups[k] = g = [e["ts"], e["ts"], 1]
                rows.append(("attempts", k, g))
        elif e["ev"] in ("case", "storage", "result", "domains", "server-instance", "late", "done"):
            rows.append(("event", e, None))
    out_rows = []
    for kind, a, g in rows:
        if kind == "attempts":
            tag, method, err, root = a
            out_rows.append([f"{g[0]}–{g[1]}", "app", f"{g[2]} failed attempts", f"tag={tag} method={method} error={err} rootExists={root}"])
        else:
            e = a
            keep = ("tag", "method", "ok", "attempts", "totalMs", "lookupMs", "storage", "rootExisted", "itemExisted", "rootExists", "itemExists", "storageExists", "started", "footprint", "error", "ms", "count", "ids", "name", "phase")
            fields = " ".join(f"{k}={code(e[k]) if k == 'error' else e[k]}" for k in keep if k in e and not (k == "storage" and e["ev"] == "server-instance"))
            if e["ev"] == "server-instance" and "started" in e:
                fields += " processStart=" + datetime.datetime.fromtimestamp(float(e["started"]), datetime.timezone.utc).strftime("%H:%M:%S.%f")[:12]
            out_rows.append([e["ts"], e["proc"], e["ev"], fields])
    for e in sysev:
        if e is first_seen.get(e["ev"]) or e["ev"] in ("domain-created", "sync", "extension-launch"):
            out_rows.append([e["ts"][:12], e["proc"], e["ev"], ""])
    out_rows.sort(key=lambda r: r[0])
    print(table(["time", "process", "event", "fields"], out_rows))

    start = next((e for e in events if e["ev"] == "storage"), None)
    ok = next((e for e in events if e["ev"] == "result" and e.get("ok") == "1"), None)
    created = first_seen.get("domain-created")
    print()
    if start:
        t0 = start["t"]
        print(f"- first lookup: {start['ts']}")
        print(f"- first answer: {ok['ts']}, {ok['t'] - t0:.1f} s after the first lookup, tag {ok.get('tag')}, method {ok.get('method')}" if ok else "- first answer: none")
        print(f"- default domain created: {created['ts']}, {created['t'] - t0:.1f} s after the first lookup, by {created['proc']}" if created else "- default domain created: not logged")
    print()


def main():
    out = sys.argv[1]
    print("# File Provider first launch after install\n")
    for name in sys.argv[2:]:
        report(out, name)


main()
