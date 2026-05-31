#!/usr/bin/env bash
# Generate the Redbench workload.csv that run.sh replays, and place it at
# $WORKLOAD_CSV. Clones Redbench (pinned), downloads the Redset trace, runs the
# generator. Heavy + optional: skip if $WORKLOAD_CSV already exists.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

src=$ROOT/src/redbench
redset=$ROOT/src/redset-$REDSET_DATASET.parquet

command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

[ -d "$src/.git" ] || git clone "$REDBENCH_REPO" "$src"
git -C "$src" -c advice.detachedHead=false checkout -q "$REDBENCH_REF"
cd "$src"
uv sync

[ -f "$redset" ] || uv run --with awscli aws s3 cp --no-sign-request "$REDSET_URL" "$redset"

uv run python src/redbench/run.py \
  --redset_path "$redset" --output_dir output \
  --instance_id "$INSTANCE_ID" --database_id "$DATABASE_ID" \
  --generation_strategy "$GEN_STRATEGY" \
  --config_path_matching src/redbench/matching/config/default.json

csv=$(find output/generated_workloads -name workload.csv | head -1)
[ -n "$csv" ] || { echo "no workload.csv produced under $src/output"; exit 1; }
mkdir -p "$(dirname "$WORKLOAD_CSV")"
cp "$csv" "$WORKLOAD_CSV"
echo "workload -> $WORKLOAD_CSV ($(wc -l < "$WORKLOAD_CSV") rows)"
