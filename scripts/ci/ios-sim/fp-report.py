import collections
import re
import statistics
import sys

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\S*\s+\S+\s+(.+?)\[(\d+):[0-9a-fx]+\]\s+(?:\[[^\]]*\]\s+)?FPX (\S+)(.*)$")
SYSTEM_WORDS = re.compile(r"suspend|resum|terminat|launch|exit|kill|jetsam|assertion|invalid|denied|error|fail", re.I)
RB_WHO = re.compile(r"\[(?:xpcservice|app|application)<(chat\.simplex\.app[A-Za-z.-]*)")
RB_WHAT = re.compile(r"[\]}>]:(\d+)\] (Suspending|Resuming|[Tt]erminat\w*|Process exited|Shutdown)")
FPD_SESSION = re.compile(r"(inFlightRequest=\w+, lifeExtenders=\w+|because [^#]*)")


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
    out += ["| " + " | ".join(str(c).replace("|", "/") for c in row) + " |" for row in rows]
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

    print("\n## Process outside SimpleX\n")
    rows = [[e["ts"], e["proc"], e["event"], " ".join(f"{k}={v}" for k, v in e.items() if k not in ("ts", "proc", "event", "pid"))[:300]] for e in events if e["event"].startswith("foreign")]
    print(table(["time", "process", "event", "fields"], rows) if rows else "none")

    print("\n## Extension entry points\n")
    counts = collections.Counter((e["event"], e.get("id", e.get("service", ""))) for e in events if e["event"] in ("server-identifier", "server-sources", "server-endpoint", "server-accept", "server-enumerator", "server-item", "server-placeholder", "server-provide"))
    print(table(["entry point", "item or service", "calls"], [[k[0], k[1], v] for k, v in counts.items()]) if counts else "none")

    print("\n## Steps\n")
    with open(sys.argv[3], errors="replace") as f:
        print("```\n" + f.read() + "\n```")

    with open(sys.argv[2], errors="replace") as f:
        system = [raw.rstrip("\n") for raw in f]

    print("\n## RunningBoard transitions\n")
    rows = []
    for raw in system:
        if "runningboardd" not in raw:
            continue
        who = RB_WHO.search(raw)
        what = RB_WHAT.search(raw)
        if who and what:
            rows.append([raw[11:23], who.group(1), what.group(1), what.group(2)])
    print(table(["time", "process", "pid", "transition"], rows) if rows else "none")

    print("\n## Terminations by RunningBoard\n")
    rows = [[raw[11:23], raw[raw.find("Terminating with context"):][:260]] for raw in system if "runningboardd" in raw and "Terminating with context" in raw and "chat.simplex" in raw]
    print(table(["time", "context"], rows) if rows else "none")

    print("\n## fileproviderd sessions of the extension\n")
    rows = []
    for raw in system:
        if "fileproviderd" in raw and "FPDExtensionSession(chat.simplex.app.SimpleX-FP" in raw and ("Invalidating" in raw or "Keeping" in raw):
            m = FPD_SESSION.search(raw)
            rows.append([raw[11:23], "invalidated" if "Invalidating" in raw else "kept", m.group(1) if m else ""])
    compact = [r for i, r in enumerate(rows) if i == 0 or r[1:] != rows[i - 1][1:]]
    print(table(["time", "session", "reason"], compact[:120]) if compact else "none")

    print("\n## System log lines about the extension\n")
    lines = [raw[:400] for raw in system if ("SimpleX FP" in raw or "SimpleX-FP" in raw) and SYSTEM_WORDS.search(raw) and "launchservices:record" not in raw and "runningboard" not in raw]
    print(f"{len(lines)} lines\n")
    print("```\n" + "\n".join(lines[:150]) + "\n```")


main()
