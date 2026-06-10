#!/usr/bin/env bash
# CARMA grid sweep for the active experiment. EVERYTHING streams to stdout -> ONE log:
#   tmux new-session -d -s grid 'bash experiments/<name>/sweep.sh 2>&1 | tee /tmp/grid.log'
#   tail -f /tmp/grid.log
# Runs go to completion (no stall guard); rc!=0 from a run = infra failure -> abort.
# Env knobs: KS, REPS, QUERIES, EXEC_WAIT, and NAME_PREFIX (tags run names, e.g.
# per network condition, so separate passes don't collide on the resume check).
set +e
. "$(dirname "$0")/common.sh"

tmux kill-session -t carma 2>/dev/null; pkill -f "ballista-cli --host" 2>/dev/null; pkill -f "run-core.sh" 2>/dev/null; sleep 3

# Expected executor count = one per worker node (daemonset). Never benchmark a
# partial cluster: spin until ALL are Running, fail after EXEC_WAIT seconds.
EXECS_WANT=$(echo $WORKER_NODES | wc -w)
EXEC_WAIT="${EXEC_WAIT:-600}"
wait_execs() { local got n=0; while [ $((n * 5)) -lt "$EXEC_WAIT" ]; do
  got=$(kubectl -n "$NAMESPACE" get pods -l app=ballista-executor --no-headers 2>/dev/null | grep -c Running)
  [ "$got" -ge "$EXECS_WANT" ] && return 0
  [ $((n % 12)) -eq 0 ] && echo "   waiting: $got/$EXECS_WANT executors Running"
  n=$((n+1)); sleep 5
done; return 1; }

# per-run node prep: performance governor, no turbo, disable idle states, drop caches.
prep() { for n in $WORKER_NODES; do ssh -o BatchMode=yes -o ConnectTimeout=8 "$n" '
  for c in /sys/devices/system/cpu/cpu*/cpufreq; do echo performance | sudo tee $c/scaling_governor >/dev/null 2>&1; sudo tee $c/scaling_min_freq < $c/scaling_max_freq >/dev/null 2>&1; done
  [ -e /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1
  [ -e /sys/devices/system/cpu/intel_pstate/min_perf_pct ] && echo 100 | sudo tee /sys/devices/system/cpu/intel_pstate/min_perf_pct >/dev/null 2>&1
  for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]; do echo 1 | sudo tee $s/disable >/dev/null 2>&1; done
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null' 2>/dev/null; done; }

KS="${KS:-1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40}"; REPS="${REPS:-1 2 3 4 5}"; QUERIES="${QUERIES:-1000}"

[ -f "$WORKLOAD_CSV" ] || { echo "FATAL: $WORKLOAD_CSV missing - run scripts/gen-workload.sh first"; exit 1; }
total=$(( $(echo $KS | wc -w) * $(echo $REPS | wc -w) )); i=0; ran=0; sweep_start=$(date +%s)
fmt() { printf "%02d:%02d:%02d" $(($1/3600)) $(($1%3600/60)) $(($1%60)); }

# Resume: a point is done if some earlier run dir for it captured all jobs.
point_done() { local m; for m in "$RUNS_DIR"/$1-*/meta.txt; do
  [ -f "$m" ] && [ "$(sed -n 's/^jobs=//p' "$m")" = "$QUERIES" ] && return 0
done; return 1; }

echo "############################################################"
echo "## CARMA grid sweep [$STORAGE]: $total points (K={$KS} x rep={$REPS}), $QUERIES queries each"
echo "## no stall guard (runs go to completion) | started $(date '+%F %T')"
echo "############################################################"

for rep in $REPS; do
  for K in $KS; do
    i=$((i+1)); name=${NAME_PREFIX:-}g${K}r${rep}; t0=$(date +%s)
    if point_done "$name"; then echo "## [$i/$total] $name already complete - skip"; continue; fi
    echo
    echo "############################################################"
    echo "## [$i/$total] $name   K=$K  rep=$rep   start $(date +%T)"
    echo "############################################################"

    echo "-- deploy (wipe + redeploy + pin) --------------------------"
    "$EXPERIMENT_DIR/deploy.sh"
    echo "-- wait for $EXECS_WANT executors --------------------------------"
    wait_execs && echo "   ok: $EXECS_WANT executors Running" \
      || { echo "## ABORT: <$EXECS_WANT executors Running after ${EXEC_WAIT}s - cluster unhealthy, fix and restart sweep"; exit 1; }
    echo "-- node prep (governor/turbo/idle/caches) ------------------"
    prep; echo "   prep done"

    echo "-- run: $QUERIES queries @ concurrency $K (live below; runs to completion) --"
    "$EXPERIMENT_DIR/run.sh" "$QUERIES" "$K" "$name" &
    runpid=$!
    wait "$runpid"; rc=$?
    pkill -x carma_submit 2>/dev/null
    [ "$rc" -ne 0 ] && { echo "## ABORT: $name failed rc=$rc - fix and restart sweep"; exit 1; }

    ran=$((ran+1)); dur=$(( $(date +%s)-t0 )); elapsed=$(( $(date +%s)-sweep_start ))
    avg=$(( elapsed / ran )); eta=$(( avg * (total-i) ))
    echo "## [$i/$total] $name DONE rc=$rc in $(fmt $dur)   | $(grep -hE 'jobs=' "$RUNS_DIR"/${name}-*/meta.txt 2>/dev/null | head -1)"
    echo "## progress: $i/$total done | sweep elapsed $(fmt $elapsed) | est. remaining $(fmt $eta)"
  done
done
echo
echo "## GRID COMPLETE $(date '+%F %T')   total wall-clock $(fmt $(( $(date +%s)-sweep_start )))"
