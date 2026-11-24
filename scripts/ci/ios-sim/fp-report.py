import collections
import re
import statistics
import sys

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\S*\s+\S+\s+(.+?)\[(\d+):[0-9a-fx]+\]\s+(?:\[[^\]]*\]\s+)?FPX (\S+)(.*)$")
SYSTEM_WORDS = re.compile(r"suspend|resum|terminat|launch|exit|kill|jetsam|assertion|invalid|denied|error|fail", re.I)


def parse(path):
    events = []
    with open(path, errors="replace") as f:
        for raw in f:
            m = LINE.match(raw.rstrip("\n"))
            if not m:
                continue
            ts, proc, pid, event, rest = m.groups()
            fields = dict(kv.split("=", 1) for kv in rest.split() if "=" in kv)
            fields.update({"ts": ts[11:23], "proc": proc, "event": event})
            events.append(fields)
    return events


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def main():
    events = parse(sys.argv[1])
    results = [e for e in events if e["event"] == "result"]
    attempts = [e for e in events if e["event"] == "attempt"]

    print("# File Provider coordinator experiment\n")

    print("## Calls by process and lookup\n")
    groups = collections.OrderedDict()
    for e in results:
        groups.setdefault((e.get("caller", "?"), e.get("method", "?")), []).append(e)
    rows = []
    for (caller, method), rs in groups.items():
        ok = [r for r in rs if r.get("ok") == "1"]
        times = [int(r.get("totalMs", "0")) for r in ok]
        errors = sorted({r.get("error", "") for r in rs if r.get("ok") != "1"} | {a.get("error", "") for a in attempts if a.get("caller") == caller and a.get("method") == method})
        rows.append([
            caller,
            method,
            f"{len(ok)}/{len(rs)}",
            times[0] if times else "-",
            int(statistics.median(times)) if times else "-",
            max(times) if times else "-",
            "<br>".join(e for e in errors if e) or "-",
        ])
    print(table(["process", "lookup", "ok/calls", "first ms", "median ms", "max ms", "errors"], rows))

    print("\n## Results in order\n")
    rows = []
    for e in results:
        if e.get("tag", "").startswith("burst"):
            continue
        rows.append([
            e["ts"],
            e.get("caller"),
            e.get("tag"),
            e.get("method"),
            "ok" if e.get("ok") == "1" else "fail",
            e.get("attempts"),
            e.get("totalMs"),
            e.get("lookupMs", "-"),
            e.get("replyMs", "-"),
            e.get("server", "-"),
            e.get("footprint", "-"),
            e.get("services", e.get("error", "-")),
        ])
    print(table(["time", "process", "tag", "lookup", "result", "attempts", "total ms", "lookup ms", "reply ms", "extension pid", "footprint", "services or error"], rows))

    print("\n## Extension processes\n")
    rows = [[e["ts"], e.get("pid"), e.get("n"), e.get("started"), e.get("footprint"), e.get("storage")] for e in events if e["event"] == "server-instance"]
    print(table(["time", "pid", "instance", "started", "footprint", "storage"], rows))
    footprints = [int(e["footprint"]) for e in events if e.get("footprint", "").isdigit()]
    if footprints:
        print(f"\nLargest footprint reported: {max(footprints) / 1048576:.1f} MiB")

    print("\n## Messages from the extension to the holder\n")
    rows = [[e["ts"], e["proc"], e.get("caller"), e.get("from"), e.get("tag")] for e in events if e["event"] == "notify"]
    print(table(["time", "receiver", "holder", "from", "tag"], rows) if rows else "none")
    rows = [[e["ts"], e.get("from"), e.get("tag"), e.get("peer"), e.get("holders"), e.get("notified")] for e in events if e["event"] == "server-ping"]
    print("\nCalls handled by the extension:\n")
    print(table(["time", "from", "tag", "peer pid", "holders", "notified"], rows) if rows else "none")

    print("\n## Connection events\n")
    rows = [[e["ts"], e["proc"], e["event"], e.get("caller", e.get("peer", "")), e.get("phase", ""), e.get("ms", "")] for e in events if e["event"] in ("interrupted", "invalidated", "late", "server-invalidated", "server-notify-error", "crash-sent", "crash-failed", "server-crash", "notifications", "storage", "manager")]
    print(table(["time", "process", "event", "caller or peer", "phase", "ms"], rows) if rows else "none")

    print("\n## Extension entry points\n")
    counts = collections.Counter((e["event"], e.get("id", e.get("service", ""))) for e in events if e["event"] in ("server-identifier", "server-sources", "server-endpoint", "server-accept", "server-enumerator", "server-item", "server-placeholder", "server-provide"))
    print(table(["entry point", "item or service", "calls"], [[k[0], k[1], v] for k, v in counts.items()]) if counts else "none")

    print("\n## Steps\n")
    with open(sys.argv[3], errors="replace") as f:
        print("```\n" + f.read() + "\n```")

    print("\n## System log lines about the extension\n")
    lines = []
    with open(sys.argv[2], errors="replace") as f:
        for raw in f:
            if ("SimpleX FP" in raw or "SimpleX-FP" in raw) and SYSTEM_WORDS.search(raw):
                lines.append(raw.rstrip("\n")[:400])
    print(f"{len(lines)} lines\n")
    print("```\n" + "\n".join(lines[:150]) + "\n```")


main()
