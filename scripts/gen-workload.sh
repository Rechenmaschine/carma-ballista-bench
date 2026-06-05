#!/usr/bin/env bash
# Generate the Redbench workload.csv that run.sh replays, and install it at
# $WORKLOAD_CSV. That fixed path is the bench's stable interface: the generator
# writes into a config-hashed dir (matching_<hash>/) that .env can't reference
# statically, and the install also freezes the workload against later
# regeneration. Idempotent + resumable:
#   - $WORKLOAD_CSV already installed        -> no-op (delete it to regenerate)
#   - generator output for this config exists -> just install it (cheap)
#   - otherwise                               -> full generation (clones
#     Redbench, downloads the ~18 GB Redset trace)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

src=$ROOT/src/redbench
redset=$ROOT/src/redset-$REDSET_DATASET.parquet

[ -f "$WORKLOAD_CSV" ] && {
  echo "workload already installed: $WORKLOAD_CSV ($(wc -l < "$WORKLOAD_CSV") rows) - delete it to regenerate"
  exit 0
}

# Output for the .env config, if a previous (possibly interrupted) run made it.
find_csv() { find "$src/output/generated_workloads" \
  -path "*/$REDSET_DATASET/cluster_$INSTANCE_ID/database_$DATABASE_ID/${GEN_STRATEGY}_*" \
  -name workload.csv 2>/dev/null | head -1; }

csv=$(find_csv || true)
if [ -n "$csv" ]; then
  echo "found existing generator output for this config, skipping generation: $csv"
else
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
  cd - >/dev/null

  csv=$(find_csv || true)
  [ -n "$csv" ] || { echo "no workload.csv produced under $src/output"; exit 1; }
fi

mkdir -p "$(dirname "$WORKLOAD_CSV")"
cp "$csv" "$WORKLOAD_CSV"
echo "workload -> $WORKLOAD_CSV ($(wc -l < "$WORKLOAD_CSV") rows)"
