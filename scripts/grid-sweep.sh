#!/usr/bin/env bash
# CARMA grid sweep. EVERYTHING streams to stdout -> ONE log. Launch with:
#   tmux new-session -d -s grid 'bash scripts/grid-sweep.sh 2>&1 | tee /tmp/grid.log'
#   tail -f /tmp/grid.log
# Stall guard: a run is killed ONLY if no query completes for QUERY_TIMEOUT
# (a slow-but-progressing run is fine; a genuinely stuck query/stage is not).
set +e
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

tmux kill-session -t carma 2>/dev/null; pkill -f "ballista-cli --host" 2>/dev/null; pkill -f "scripts/run.sh" 2>/dev/null; sleep 3

# Expected executor count = one per worker node (daemonset), NOT hardcoded.
# Never benchmark a partial cluster: spin until ALL are Running, fail after
# EXEC_WAIT seconds (-> sweep aborts). (locals: MUST NOT clobber the global
# point counter - a `for i` here once corrupted [i/total].)
EXECS_WANT=$(echo $WORKER_NODES | wc -w)
EXEC_WAIT="${EXEC_WAIT:-600}"
wait_execs() { local got n=0; while [ $((n * 5)) -lt "$EXEC_WAIT" ]; do
  got=$(kubectl -n "$NAMESPACE" get pods -l app=ballista-executor --no-headers 2>/dev/null | grep -c Running)
  [ "$got" -ge "$EXECS_WANT" ] && return 0
  [ $((n % 12)) -eq 0 ] && echo "   waiting: $got/$EXECS_WANT executors Running"
  n=$((n+1)); sleep 5
done; return 1; }

# per-run node prep: performance governor, no turbo, disable idle states, drop caches (reproducible timing)
prep() { for n in $WORKER_NODES; do ssh -o BatchMode=yes -o ConnectTimeout=8 "$n" '
  for c in /sys/devices/system/cpu/cpu*/cpufreq; do echo performance | sudo tee $c/scaling_governor >/dev/null 2>&1; sudo tee $c/scaling_min_freq < $c/scaling_max_freq >/dev/null 2>&1; done
  [ -e /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1
  [ -e /sys/devices/system/cpu/intel_pstate/min_perf_pct ] && echo 100 | sudo tee /sys/devices/system/cpu/intel_pstate/min_perf_pct >/dev/null 2>&1
  for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]; do echo 1 | sudo tee $s/disable >/dev/null 2>&1; done
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null' 2>/dev/null; done; }

KS="${KS:-1 2 3 4 5 6 7 8 9 10 15 20}"; REPS="${REPS:-1 2 3 4 5}"; QUERIES="${QUERIES:-1000}"

# Preflight: don't start a multi-hour sweep that can't run a single point.
[ -f "$WORKLOAD_CSV" ] || { echo "FATAL: $WORKLOAD_CSV missing - run scripts/gen-workload.sh first"; exit 1; }
total=$(( $(echo $KS | wc -w) * $(echo $REPS | wc -w) )); i=0; sweep_start=$(date +%s)
fmt() { printf "%02d:%02d:%02d" $(($1/3600)) $(($1%3600/60)) $(($1%60)); }

echo "############################################################"
echo "## CARMA grid sweep: $total points (K={$KS} x rep={$REPS}), $QUERIES queries each"
echo "## no stall guard (runs go to completion) | started $(date '+%F %T')"
echo "############################################################"

for rep in $REPS; do
  for K in $KS; do
    i=$((i+1)); name=g${K}r${rep}; t0=$(date +%s)
    echo
    echo "############################################################"
    echo "## [$i/$total] $name   K=$K  rep=$rep   start $(date +%T)"
    echo "############################################################"

    echo "-- deploy (wipe + redeploy + pin) --------------------------"
    ./scripts/deploy.sh
    echo "-- wait for $EXECS_WANT executors --------------------------------"
    wait_execs && echo "   ok: $EXECS_WANT executors Running" \
      || { echo "## ABORT: <$EXECS_WANT executors Running after ${EXEC_WAIT}s - cluster unhealthy, fix and restart sweep"; exit 1; }
    echo "-- node prep (governor/turbo/idle/caches) ------------------"
    prep; echo "   prep done"

    echo "-- run: $QUERIES queries @ concurrency $K (live below; runs to completion, no stall guard) --"
    ./scripts/run.sh "$QUERIES" "$K" "$name" &
    runpid=$!
    wait "$runpid"; rc=$?
    pkill -x carma_submit 2>/dev/null
    # rc!=0 means setup/infra failure (run.sh is set -e), not slowness: abort loudly
    # instead of grinding out 60 unusable points.
    [ "$rc" -ne 0 ] && { echo "## ABORT: $name failed rc=$rc - fix and restart sweep"; exit 1; }

    dur=$(( $(date +%s)-t0 )); elapsed=$(( $(date +%s)-sweep_start ))
    avg=$(( elapsed / i )); eta=$(( avg * (total-i) ))
    echo "## [$i/$total] $name DONE rc=$rc in $(fmt $dur)   | $(grep -hE 'jobs=' /storage/carma/runs/${name}-*/meta.txt 2>/dev/null | head -1)"
    echo "## progress: $i/$total done | sweep elapsed $(fmt $elapsed) | est. remaining $(fmt $eta)"
  done
done
echo
echo "## GRID COMPLETE $(date '+%F %T')   total wall-clock $(fmt $(( $(date +%s)-sweep_start )))"
