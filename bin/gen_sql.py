#!/usr/bin/env python3
# Turn a Redbench workload.csv into SQL for ballista-cli:
#   setup.sql      - CREATE EXTERNAL TABLE per parquet dir in --data-dir
#   workload.sql   - filtered SELECTs (or workload.<i>.sql when --shards > 1)
#
# Filtering+sorting the 7.6M-row CSV is slow, so it is done ONCE into a cache
# (<workload>.sorted.sql, one query per line, arrival-sorted). Subsequent runs
# just take the first --limit lines and shard them, which is near-instant.
import argparse, csv, os, sys

csv.field_size_limit(1 << 30)


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "t", "yes")


def build_cache(workload, cache):
    print(f"parsing {workload} -> {cache} (one-time)", flush=True)
    rows = []
    with open(workload, newline="") as f:
        for i, r in enumerate(csv.DictReader(f), 1):
            if i % 1_000_000 == 0:
                print(f"  {i:,} rows...", flush=True)
            sql = (r.get("sql") or "").strip()
            if not sql or truthy(r.get("was_aborted")):
                continue
            if (r.get("query_type") or "select").strip().lower() != "select":
                continue
            rows.append((r.get("arrival_timestamp") or "", sql))
    rows.sort(key=lambda x: x[0])
    tmp = cache + ".tmp"
    with open(tmp, "w") as f:
        for _, sql in rows:
            f.write(sql.rstrip().rstrip(";") + ";\n")
    os.replace(tmp, cache)
    print(f"cached {len(rows):,} queries", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--workload", required=True)
    p.add_argument("--data-dir", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--limit", type=int, default=0)
    p.add_argument("--shards", type=int, default=1)
    a = p.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)

    tables = sorted(d for d in os.listdir(a.data_dir)
                    if os.path.isdir(os.path.join(a.data_dir, d)) and not d.startswith("."))
    with open(os.path.join(a.out_dir, "setup.sql"), "w") as f:
        for t in tables:
            f.write(f"CREATE EXTERNAL TABLE {t} STORED AS PARQUET "
                    f"LOCATION '{os.path.join(a.data_dir, t)}';\n")

    cache = a.workload + ".sorted.sql"
    if not os.path.exists(cache) or os.path.getmtime(cache) < os.path.getmtime(a.workload):
        build_cache(a.workload, cache)

    k = max(1, a.shards)
    outs = [open(os.path.join(a.out_dir, "workload.sql" if k == 1 else f"workload.{i}.sql"), "w")
            for i in range(k)]
    n = 0
    with open(cache) as f:
        for line in f:
            if a.limit and n >= a.limit:
                break
            outs[n % k].write(line)
            n += 1
    for f in outs:
        f.close()
    print(f"{len(tables)} tables, {n} queries, {k} shard(s) -> {a.out_dir}", flush=True)


if __name__ == "__main__":
    main()
