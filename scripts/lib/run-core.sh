#!/usr/bin/env bash
# Run one benchmark for the active experiment: run-core.sh [queries] [concurrency] [name]
# Results go to a fresh $RUNS_DIR/<name>/ (never overwritten). Identical across
# experiments; only the table LOCATION ($LOCATION_PREFIX) and storage differ.
set -euo pipefail
. "$(dirname "$0")/common.sh"

# Ctrl-C cleanly stops the drivers and the progress tail.
cleanup() {
  trap - INT TERM
  echo; echo "stopping..."
  [ -n "${prog:-}" ] && pkill -P "$prog" 2>/dev/null
  pkill -P $$ 2>/dev/null
  exit 130
}
trap cleanup INT TERM

queries=${1:-2000}
concurrency=${2:-1}
ts=$(date +%Y%m%d-%H%M%S)
name=${3:+$3-}$ts
run=$RUNS_DIR/$name
mkdir -p "$run"

# S3 storage reads remote: make sure MinIO is up before timing anything.
if [ "$STORAGE" = s3 ]; then
  echo ">> waiting for MinIO..."
  kubectl -n "$NAMESPACE" rollout status deploy/minio --timeout=180s
fi

sched=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-scheduler -o jsonpath='{.items[0].status.podIP}')
cli=$BALLISTA_SRC/target/release/ballista-cli

# Require one REGISTERED executor per worker node (a partial cluster skews every
# point): poll the scheduler API, fail after EXEC_WAIT seconds.
want=$(echo $WORKER_NODES | wc -w)
EXEC_WAIT="${EXEC_WAIT:-600}"
n=0
while :; do
  execs=$(curl -s "http://$sched:$SCHEDULER_PORT/api/executors" | grep -o '"host":' | wc -l || true)
  [ "$execs" -ge "$want" ] && break
  [ $((n * 5)) -ge "$EXEC_WAIT" ] && { echo "only $execs/$want executors registered after ${EXEC_WAIT}s (scheduler $sched) - check scripts/status.sh"; rmdir "$run"; exit 1; }
  [ $((n % 12)) -eq 0 ] && echo "  waiting: $execs/$want executors registered"
  n=$((n+1)); sleep 5
done
echo ">> run '$name' ($STORAGE): $queries queries, concurrency $concurrency, scheduler $sched ($execs executors)"

echo ">> [1/3] generating SQL..."
# --location-prefix sets the CREATE EXTERNAL TABLE LOCATION (local dir or s3://);
# --data-dir is only the local Parquet used to enumerate table names.
python3 bin/gen_sql.py --workload "$WORKLOAD_CSV" --data-dir "$DATA_DIR" \
  --location-prefix "$LOCATION_PREFIX" --out-dir "$run" --limit "$queries"

start=$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ)

# Record the shared trace file's current size so we can slice out this run's portion.
trace_file="$TRACE_DIR/stages.jsonl"
trace_off=$([ -f "$trace_file" ] && wc -c < "$trace_file" || echo 0)

echo ">> [2/3] submitting queries (this is the timed part)..."
# Stream the scheduler's ROLLUP metrics to disk LIVE and drive the progress
# counter from the same stream (a post-hoc logs --since-time loses rotated lines).
( kubectl -n "$NAMESPACE" logs deploy/ballista-scheduler -f --since-time="$start" 2>/dev/null \
    | grep --line-buffered '"kind":"' \
    | tee "$run/rollups.jsonl" \
    | grep --line-buffered '"kind":"job"' \
    | awk "{ printf \"\r  completed: %d/$queries\", NR; fflush() }" ) &
prog=$!

# Work-conserving submission via carma_submit: $concurrency persistent sessions
# register tables once (setup.sql) then drain one arrival-ordered queue.
submitter="${cli%/*}/carma_submit"
[ -x "$submitter" ] || { echo "carma_submit not built at $submitter -- run scripts/build.sh"; rmdir "$run" 2>/dev/null; exit 1; }
"$submitter" --host "$sched" --port "$SCHEDULER_PORT" \
  --concurrency "$concurrency" --queries-dir "$run/queries" --setup "$run/setup.sql" \
  > "$run/cli.log" 2>&1

# Wait for trailing rollups to flush (the final "job" line travels kubelet ->
# apiserver -> kubectl -f after the client already has results).
expected=$(ls "$run"/queries/q*.sql 2>/dev/null | wc -l | tr -d ' ')
for _ in $(seq 1 30); do
  got=$(grep -c '"kind":"job"' "$run/rollups.jsonl" 2>/dev/null || true)
  [ "${got:-0}" -ge "$expected" ] && break
  sleep 1
done
pkill -P "$prog" 2>/dev/null; kill "$prog" 2>/dev/null || true; echo

tail -c "+$((trace_off + 1))" "$trace_file" > "$run/stages.jsonl" 2>/dev/null || : > "$run/stages.jsonl"
echo ">> [3/3] full trace -> $run/stages.jsonl  (rollups -> $run/rollups.jsonl)"

# Run-level cluster shape: ONLY what we measure off the live cluster.
memraw=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.capacity.memory}' 2>/dev/null || echo "0Ki")
case "$memraw" in
  *Ki) mem_bytes=$(( ${memraw%Ki} * 1024 )) ;;
  *Mi) mem_bytes=$(( ${memraw%Mi} * 1048576 )) ;;
  *Gi) mem_bytes=$(( ${memraw%Gi} * 1073741824 )) ;;
  *[0-9]) mem_bytes=$memraw ;;
  *) mem_bytes=0 ;;
esac
cat > "$run/cluster.json" <<JSON
{
  "cluster_hardware": {
    "num_executors": $execs,
    "cores_per_executor": $TASK_SLOTS,
    "memory_per_executor_bytes": $mem_bytes
  }
}
JSON

# Config snapshot: capture EXACTLY what produced this run.
cp ./.env "$run/env.snapshot"
cp "$EXPERIMENT_DIR/experiment.env" "$run/experiment.env.snapshot"
{
  echo "bench_repo_rev=$(git rev-parse --short HEAD 2>/dev/null)$([ -n "$(git status --porcelain 2>/dev/null)" ] && echo -dirty)"
  echo "storage=$STORAGE"
  echo "minio_egress_bw=${MINIO_EGRESS_BW:-}"
  echo "ballista_ref=$BALLISTA_REF"
  echo "ballista_rev=$(git -C "$BALLISTA_SRC" rev-parse --short HEAD 2>/dev/null)"
  echo "image_tag=$IMAGE_TAG"
  echo "task_slots=$TASK_SLOTS"
  echo "control_node=$CONTROL_NODE"
  echo "worker_nodes=$WORKER_NODES"
  echo "executor_cpu_request=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-executor -o jsonpath='{.items[0].spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
  echo "executor_cpu_limit=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-executor -o jsonpath='{.items[0].spec.containers[0].resources.limits.cpu}' 2>/dev/null)"
  echo "executor_qos=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-executor -o jsonpath='{.items[0].status.qosClass}' 2>/dev/null)"
  exnode=$(kubectl -n "$NAMESPACE" get pod -l app=ballista-executor -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  echo "executor_node=$exnode"
  echo "executor_node_cpus=$(kubectl get node "$exnode" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)"
  echo "smt_control=$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)"
} > "$run/config.txt"

submitted=$(ls "$run"/queries/q*.sql 2>/dev/null | wc -l | tr -d ' ')
jobs=$(grep -c '"kind":"job"' "$run/rollups.jsonl" || true)
stage_records=$(grep -c '"kind":"stage_trace"' "$run/stages.jsonl" || true)
{
  echo "queries_requested=$queries"
  echo "queries_submitted=$submitted"
  echo "concurrency=$concurrency"
  echo "storage=$STORAGE"
  echo "date=$(date -Is)"
  echo "jobs=$jobs"
  echo "stage_records=$stage_records"
} | tee "$run/meta.txt"
if [ "$stage_records" -eq 0 ]; then
  echo "WARNING: no stage_trace records captured - is BALLISTA_STAGE_TRACE_FILE set on the scheduler? (re-run deploy.sh after pulling)" | tee -a "$run/meta.txt"
fi
if [ "$jobs" -lt "$submitted" ]; then
  echo "WARNING: captured $jobs/$submitted job rollups - cluster may have been unhealthy mid-run" | tee -a "$run/meta.txt"
fi
echo "results: $run"
