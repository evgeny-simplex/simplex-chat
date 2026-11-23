import argparse
import json
import statistics
import sys
import time
import traceback
from itertools import islice
from pathlib import Path

import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_data

DBS = {"master": "probe_master", "head": "probe_head"}
COPY_CHUNK = 100_000
SETTINGS = [
    "server_version", "shared_buffers", "work_mem", "effective_cache_size", "random_page_cost", "jit",
    "jit_above_cost", "max_parallel_workers_per_gather", "autovacuum", "fsync", "synchronous_commit",
]


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def connect(db: str, autocommit: bool = True) -> psycopg.Connection:
    return psycopg.connect(host="localhost", user="postgres", dbname=db, autocommit=autocommit, options="-c statement_timeout=600000")


def create_databases(schemas: dict, setup_sql: str):
    with connect("postgres") as admin:
        for name, db in DBS.items():
            admin.execute(f"DROP DATABASE IF EXISTS {db}")
            admin.execute(f"CREATE DATABASE {db}")
            with connect(db) as c:
                c.execute(Path(schemas[name]).read_text())
            admin.execute(f"ALTER DATABASE {db} SET search_path = test_chat_schema")
            with connect(db) as c:
                c.execute(Path(setup_sql).read_text())
            log(f"{db}: schema {schemas[name]} loaded")


def load_data(world: gen_data.World):
    loaded = {}
    for name, db in DBS.items():
        counts = {}
        with connect(db, autocommit=False) as c:
            for t in world.tables():
                cols = t.columns + t.head_columns
                n = len(cols)
                start = time.time()
                rows = 0
                source = iter(t.rows())
                with c.cursor() as cur:
                    while chunk := list(islice(source, COPY_CHUNK)):
                        with cur.copy(f"COPY {t.name} ({', '.join(cols)}) FROM STDIN") as cp:
                            for row in chunk:
                                cp.write_row(row[:n])
                        rows += len(chunk)
                counts[t.name] = rows
                log(f"{db}: {t.name} {rows} rows in {time.time() - start:.1f}s")
            c.commit()
        loaded[name] = counts
        with connect(db) as c:
            ids = c.execute(
                "SELECT table_name, column_name FROM information_schema.columns "
                "WHERE table_schema = 'test_chat_schema' AND is_identity = 'YES'"
            ).fetchall()
            for table, column in ids:
                if table in counts and counts[table]:
                    c.execute(f"SELECT setval(pg_get_serial_sequence('test_chat_schema.{table}', '{column}'), (SELECT max({column}) FROM {table}))")
            start = time.time()
            c.execute("VACUUM (ANALYZE)")
            log(f"{db}: VACUUM (ANALYZE) in {time.time() - start:.1f}s")
    return loaded


def data_checks(world: gen_data.World) -> dict:
    checks = {}
    for name, db in DBS.items():
        with connect(db) as c:
            sums = {}
            for t in world.tables():
                cols = ", ".join(t.columns)
                count, digest = c.execute(
                    f"SELECT count(*), sum(('x' || substr(md5(ROW({cols})::text), 1, 15))::bit(60)::bigint) FROM {t.name}"
                ).fetchone()
                sums[t.name] = [count, str(digest)]
            checks[name] = sums
    checks["common_columns_identical"] = checks["master"] == checks["head"]
    with connect(DBS["head"]) as c:
        def q(sql: str) -> tuple:
            return c.execute(sql).fetchone()

        per_chat = q(
            "SELECT min(n), max(n), count(*) FROM (SELECT count(*) n FROM chat_items GROUP BY contact_id, group_id, note_folder_id) s"
        )
        checks["head_stats"] = {
            "chat_items": q("SELECT count(*) FROM chat_items")[0],
            "group_items": q("SELECT count(*) FROM chat_items WHERE group_id IS NOT NULL")[0],
            "per_chat_min_max_chats": list(per_chat),
            "unread": q("SELECT count(*) FROM chat_items WHERE item_status = 'rcv_new'")[0],
            "unread_silent": q("SELECT count(*) FROM chat_items WHERE item_status = 'rcv_new' AND item_priority < 0")[0],
            "unread_high": q("SELECT count(*) FROM chat_items WHERE item_status = 'rcv_new' AND item_priority > 0")[0],
            "priority_rows": q("SELECT count(*) FROM chat_items WHERE item_priority <> 0")[0],
            "item_original_ts": q("SELECT count(*) FROM chat_items WHERE item_original_ts IS NOT NULL")[0],
            "member_via": q("SELECT count(*) FROM group_members WHERE member_via IS NOT NULL")[0],
            "delivery_tasks": q("SELECT count(*) FROM delivery_tasks")[0],
            "update_notification": q("SELECT count(*) FROM delivery_tasks WHERE update_notification = 1")[0],
            "contacts": q("SELECT count(*) FROM contacts WHERE is_user = 0")[0],
            "groups": q("SELECT count(*) FROM groups")[0],
            "group_sizes": list(q("SELECT min(n), max(n), count(*) FILTER (WHERE n = 300) FROM (SELECT count(*) n FROM group_members GROUP BY group_id) s")),
        }
    for name, db in DBS.items():
        with connect(db) as c:
            rels = c.execute(
                "SELECT c.relname, c.relkind, pg_relation_size(c.oid), c.reltuples::bigint FROM pg_class c "
                "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'test_chat_schema' "
                "AND (c.relname IN ('chat_items', 'group_members', 'delivery_tasks', 'messages') "
                "OR c.relname LIKE 'idx_chat_items%' OR c.relname LIKE 'idx_group_members%' OR c.relname LIKE 'idx_delivery_tasks%') "
                "ORDER BY c.relname"
            ).fetchall()
            checks[f"{name}_relations"] = {r[0]: {"kind": r[1], "bytes": r[2], "tuples": r[3]} for r in rels}
    return checks


def render(text: str, replacements: list, anchors: dict, k: int) -> str:
    for literal, keys, fmt in replacements:
        values = []
        for key in keys:
            v = anchors[key]
            values.append(v[k % len(v)] if isinstance(v, list) else v)
        if text.count(literal) != 1:
            raise ValueError(f"literal {literal!r} occurs {text.count(literal)} times")
        text = text.replace(literal, fmt.format(*values))
    return text


def batch_size(replacements: list, anchors: dict) -> int:
    sizes = [len(anchors[key]) for _, keys, _ in replacements for key in keys if isinstance(anchors[key], list)]
    return min([gen_data.BATCH] + sizes)


def run_explain(conn, sql: str) -> dict:
    return conn.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql).fetchone()[0][0]


def run_explain_text(conn, sql: str) -> str:
    return "\n".join(r[0] for r in conn.execute("EXPLAIN (ANALYZE, BUFFERS) " + sql).fetchall())


def timing(plan: dict) -> dict:
    top = plan["Plan"]
    jit = plan.get("JIT", {}).get("Timing", {}).get("Total")
    return {
        "planning_ms": plan.get("Planning Time", 0.0),
        "execution_ms": plan.get("Execution Time", 0.0),
        "total_ms": plan.get("Planning Time", 0.0) + plan.get("Execution Time", 0.0),
        "jit_ms": jit,
        "shared_hit": top.get("Shared Hit Blocks"),
        "shared_read": top.get("Shared Read Blocks"),
        "planning_hit": plan.get("Planning", {}).get("Shared Hit Blocks"),
        "planning_read": plan.get("Planning", {}).get("Shared Read Blocks"),
    }


def summary(runs: list, key: str) -> float:
    return statistics.median(r[key] for r in runs)


def measure_read(conns: dict, st: dict, anchors: dict, runs: int) -> dict:
    texts = {name: render(st[name], st["replacements"], anchors, 0) for name in ("master", "head") if st[name] is not None}
    result = {"sql": texts}
    for name, sql in texts.items():
        for _ in range(2):
            run_explain(conns[name], sql)
    explains = {name: [] for name in texts}
    plans = {name: [] for name in texts}
    walls = {name: [] for name in texts}
    for _ in range(runs):
        for name, sql in texts.items():
            plan = run_explain(conns[name], sql)
            explains[name].append(timing(plan))
            plans[name].append(plan)
    for _ in range(runs):
        for name, sql in texts.items():
            start = time.perf_counter()
            rows = conns[name].execute(sql).fetchall()
            walls[name].append((time.perf_counter() - start) * 1000)
            result.setdefault("rows", {})[name] = len(rows)
            result.setdefault("values", {})[name] = [[str(v) for v in row] for row in rows[:3]]
            result.setdefault("all_values", {})[name] = hash(tuple(tuple(str(v) for v in row) for row in rows))
    for name in texts:
        totals = [r["total_ms"] for r in explains[name]]
        median_index = sorted(range(len(totals)), key=totals.__getitem__)[len(totals) // 2]
        result[name] = {
            "runs": explains[name],
            "median_total_ms": statistics.median(totals),
            "median_planning_ms": summary(explains[name], "planning_ms"),
            "median_execution_ms": summary(explains[name], "execution_ms"),
            "wall_ms": walls[name],
            "median_wall_ms": statistics.median(walls[name]),
            "plan": plans[name][median_index],
            "plan_text": run_explain_text(conns[name], texts[name]),
        }
    return result


def measure_write(conns: dict, wconns: dict, st: dict, anchors: dict, runs: int) -> dict:
    n = batch_size(st["replacements"], anchors)
    batches = {
        name: [render(st[name], st["replacements"], anchors, k) for k in range(n)]
        for name in ("master", "head") if st[name] is not None
    }
    result = {"rows_per_batch": n, "sql_first": {name: b[0] for name, b in batches.items()}}
    for name, batch in batches.items():
        c = wconns[name]
        plan = run_explain(c, batch[0])
        c.rollback()
        plan_text = run_explain_text(c, batch[0])
        c.rollback()
        c.execute("SELECT probe.run_batch(%s)", (batch,))
        c.rollback()
        result[name] = {"plan": plan, "plan_text": plan_text, "single": timing(plan), "batch_ms": [], "batch_wall_ms": []}
    for _ in range(runs):
        for name, batch in batches.items():
            c = wconns[name]
            start = time.perf_counter()
            server_ms = c.execute("SELECT probe.run_batch(%s)", (batch,)).fetchone()[0]
            wall = (time.perf_counter() - start) * 1000
            c.rollback()
            result[name]["batch_ms"].append(server_ms)
            result[name]["batch_wall_ms"].append(wall)
    for name in batches:
        result[name]["median_batch_ms"] = statistics.median(result[name]["batch_ms"])
        result[name]["median_per_row_ms"] = result[name]["median_batch_ms"] / n
        conns[name].execute(f"VACUUM {st['table']}")
    return result


def measure_migrations(wconns: dict, statements: list, runs: int) -> dict:
    results = {}
    for phase, db_name in (("mig_up", "master"), ("mig_down", "head")):
        sts = [s for s in statements if s["phase"] == phase]
        c = wconns[db_name]
        for s in sts:
            results[s["id"]] = {"db": db_name, "wall_ms": [], "server_ms": [], "plan_text": None, "plan": None}
        for run in range(runs):
            try:
                for s in sts:
                    sql = s["head"]
                    is_dml = sql.lstrip().upper().startswith("UPDATE")
                    start = time.perf_counter()
                    if is_dml:
                        plan = run_explain(c, sql)
                        results[s["id"]]["server_ms"].append(timing(plan)["total_ms"])
                        if run == 0:
                            results[s["id"]]["plan"] = plan
                    else:
                        c.execute(sql)
                    results[s["id"]]["wall_ms"].append((time.perf_counter() - start) * 1000)
            finally:
                c.rollback()
        for k, s in enumerate(sts):
            if s["head"].lstrip().upper().startswith("UPDATE"):
                for prior in sts[:k]:
                    c.execute(prior["head"])
                results[s["id"]]["plan_text"] = run_explain_text(c, s["head"])
                c.rollback()
        for s in sts:
            r = results[s["id"]]
            r["median_wall_ms"] = statistics.median(r["wall_ms"]) if r["wall_ms"] else None
            r["median_server_ms"] = statistics.median(r["server_ms"]) if r["server_ms"] else None
        log(f"{phase}: " + ", ".join(f"{s['id']} {results[s['id']]['median_wall_ms']:.1f}ms" for s in sts))
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--master-schema", required=True)
    parser.add_argument("--head-schema", required=True)
    parser.add_argument("--statements", required=True)
    parser.add_argument("--setup-sql", required=True)
    parser.add_argument("--scale", type=float, default=1.0)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    spec = json.loads(Path(args.statements).read_text())
    statements = spec["statements"]
    report = {"pr": spec["pr"], "head_commit": spec["head_commit"], "base_commit": spec["base_commit"], "scale": args.scale, "runs": args.runs}

    create_databases({"master": args.master_schema, "head": args.head_schema}, args.setup_sql)
    start = time.time()
    world = gen_data.World(args.scale)
    log(f"world planned in {time.time() - start:.1f}s: {world.n} items")
    report["anchors"] = world.anchors
    report["loaded"] = load_data(world)
    report["checks"] = data_checks(world)
    log(f"data checks: common columns identical = {report['checks']['common_columns_identical']}")
    with connect("postgres") as admin:
        admin.execute("ALTER SYSTEM SET autovacuum = off")
        admin.execute("SELECT pg_reload_conf()")
        time.sleep(1)
        report["settings"] = {s: admin.execute(f"SHOW {s}").fetchone()[0] for s in SETTINGS}
        report["version"] = admin.execute("SELECT version()").fetchone()[0]
    Path(out, "raw-results.json").write_text(json.dumps(report, indent=1, default=str))

    conns = {name: connect(db) for name, db in DBS.items()}
    wconns = {name: connect(db, autocommit=False) for name, db in DBS.items()}
    results = {}
    for st in statements:
        if st["phase"] != "read":
            continue
        try:
            r = measure_read(conns, st, world.anchors, args.runs)
            results[st["id"]] = r
            log(f"read {st['id']}: " + ", ".join(f"{n} {r[n]['median_total_ms']:.2f}ms" for n in ("master", "head") if n in r))
        except Exception as e:
            results[st["id"]] = {"error": repr(e), "trace": traceback.format_exc()}
            log(f"read {st['id']}: ERROR {e!r}")
    for st in statements:
        if st["phase"] != "write":
            continue
        try:
            r = measure_write(conns, wconns, st, world.anchors, args.runs)
            results[st["id"]] = r
            log(f"write {st['id']}: " + ", ".join(f"{n} {r[n]['median_batch_ms']:.1f}ms/{r['rows_per_batch']}" for n in ("master", "head") if n in r))
        except Exception as e:
            for c in wconns.values():
                c.rollback()
            results[st["id"]] = {"error": repr(e), "trace": traceback.format_exc()}
            log(f"write {st['id']}: ERROR {e!r}")
    try:
        results.update(measure_migrations(wconns, statements, args.runs))
    except Exception as e:
        for c in wconns.values():
            c.rollback()
        results["migrations_error"] = {"error": repr(e), "trace": traceback.format_exc()}
        log(f"migrations: ERROR {e!r}")
    report["results"] = results
    Path(out, "raw-results.json").write_text(json.dumps(report, indent=1, default=str))
    log(f"wrote {out / 'raw-results.json'}")


if __name__ == "__main__":
    main()
