#!/usr/bin/env bash
# s3-central staging: build Parquet locally, bring up MinIO, upload the tables to
# its bucket once. The bucket is hostPath-backed on $MINIO_NODE, so it survives
# later deploy.sh redeploys -- run this once per cluster (re-run to refresh data).
set -euo pipefail
export EXPERIMENT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$EXPERIMENT_DIR/../../scripts/lib/common.sh"

# 1. CSV -> schema-correct Parquet on the control node (table-name + upload source).
csv=$ROOT/imdb-csv
mkdir -p "$csv" "$DATA_DIR"
[ -f "$csv/title.csv" ] || curl -L "$IMDB_URL" | tar -xz -C "$csv"
python3 bin/imdb_to_parquet.py --schema data/imdb_schema.sql --csv-dir "$csv" --out-dir "$DATA_DIR"

# 2. Ensure the namespace + MinIO are up (deploy.sh later manages them; data persists).
render manifests/00-namespace.yaml.tmpl "$EXPERIMENT_DIR/manifests/minio.yaml.tmpl" | kubectl apply -f -
kubectl -n "$NAMESPACE" rollout status deploy/minio --timeout=180s

# 3. Upload tables to s3://$BUCKET/imdb via a local port-forward (mc auto-installed).
mc=$ROOT/bin/mc
[ -x "$mc" ] || { mkdir -p "$ROOT/bin"; curl -L https://dl.min.io/client/mc/release/linux-amd64/mc -o "$mc"; chmod +x "$mc"; }
kubectl -n "$NAMESPACE" port-forward svc/minio "${MINIO_PORT}:9000" >/dev/null 2>&1 &
pf=$!; trap 'kill $pf 2>/dev/null' EXIT
sleep 3
"$mc" alias set carma "http://127.0.0.1:${MINIO_PORT}" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
"$mc" mb --ignore-existing "carma/$BUCKET"
"$mc" cp --recursive "$DATA_DIR/" "carma/$BUCKET/imdb/"
echo "uploaded $(ls -d "$DATA_DIR"/*/ | wc -l) tables to s3://$BUCKET/imdb"
