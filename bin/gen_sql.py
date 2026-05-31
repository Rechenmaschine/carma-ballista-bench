#!/usr/bin/env python3
# Generate SQL for ballista-cli from a Redbench workload.csv.
# The CSV is already arrival-sorted, so stream the first --limit executable
# SELECTs and stop. No full read, no sort, no cache: O(limit), not O(7.6M).
#   setup.sql     - CREATE EXTERNAL TABLE per parquet dir in --data-dir
#   workload.sql  - the queries (or workload.<i>.sql when --shards > 1)
import argparse, csv, os

csv.field_size_limit(1 << 30)


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "t", "yes")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--workload", required=True)
    p.add_argument("--data-dir", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--limit", type=int, default=0, help="0 = all")
    p.add_argument("--shards", type=int, default=1)
    a = p.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)

    tables = sorted(d for d in os.listdir(a.data_dir)
                    if os.path.isdir(os.path.join(a.data_dir, d)) and not d.startswith("."))
    with open(os.path.join(a.out_dir, "setup.sql"), "w") as f:
        for t in tables:
            f.write(f"CREATE EXTERNAL TABLE {t} STORED AS PARQUET "
                    f"LOCATION '{os.path.join(a.data_dir, t)}';\n")

    k = max(1, a.shards)
    outs = [open(os.path.join(a.out_dir, "workload.sql" if k == 1 else f"workload.{i}.sql"), "w")
            for i in range(k)]
    n = 0
    with open(a.workload, newline="") as f:
        for r in csv.DictReader(f):
            if a.limit and n >= a.limit:
                break
            sql = (r.get("sql") or "").strip()
            if not sql or truthy(r.get("was_aborted")):
                continue
            if (r.get("query_type") or "select").strip().lower() != "select":
                continue
            outs[n % k].write(sql.rstrip().rstrip(";") + ";\n")
            n += 1
    for f in outs:
        f.close()
    print(f"{len(tables)} tables, {n} queries, {k} shard(s) -> {a.out_dir}", flush=True)


if __name__ == "__main__":
    main()
