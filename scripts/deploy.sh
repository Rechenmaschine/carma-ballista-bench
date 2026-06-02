#!/usr/bin/env bash
# Wipe any existing deployment and recreate it fresh from the .env-rendered
# manifests. A full delete+recreate (not just `apply`) guarantees pods restart
# on the current image, even when the image tag is unchanged after a rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

vars='$NAMESPACE $CONTROL_NODE $IMAGE_TAG $DATA_DIR $WORK_DIR $TRACE_DIR $TASK_SLOTS $EXEC_MEM_LIMIT $EXEC_MEM_POOL'
render() { for t in manifests/*.yaml.tmpl; do envsubst "$vars" < "$t"; echo ---; done; }

echo ">> wiping namespace $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
echo ">> waiting for $NAMESPACE to terminate"
kubectl wait --for=delete namespace/"$NAMESPACE" --timeout=120s || {
  echo "!! namespace stuck terminating, clearing finalizers" >&2
  kubectl get ns "$NAMESPACE" -o json \
    | jq 'del(.spec.finalizers)' \
    | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f -
}
# Fresh trace file for the new scheduler. The writer opens it append-mode at
# startup (hostPath persists across pods), so truncate now that the old pod is
# gone — each deploy starts a clean trace; run.sh still slices per run on top.
echo ">> preparing trace dir $TRACE_DIR (on $CONTROL_NODE)"
mkdir -p "$TRACE_DIR" && chmod 777 "$TRACE_DIR" && : > "$TRACE_DIR/stages.jsonl"

echo ">> deploying"
render | kubectl apply -f -

# Pin the cluster's observability add-ons (dashboard + metrics-scraper) to the
# control node. They live in kube-system (not our manifests) and ship with no
# nodeSelector, so the default scheduler spreads them onto whatever worker looks
# free - landing them ON an executor node. There they (a) compete with the
# CPU-pinned executor for that node's ~2 cores of system headroom, helping tip
# it into NotReady flaps under load, and (b) become unreachable through the
# apiserver proxy whenever that worker flaps (the dashboard Service's only
# endpoint is its pod). Pinning them to $CONTROL_NODE keeps workers
# executor-only and the dashboard served from the (unloaded) control node. They
# already tolerate the control-plane taint; this adds the missing "put me here".
# Idempotent: re-asserted on every deploy, skipped if an add-on isn't installed.
echo ">> pinning observability add-ons to $CONTROL_NODE"
for d in kubernetes-dashboard kubernetes-metrics-scraper; do
  kubectl -n kube-system get deploy "$d" >/dev/null 2>&1 || { echo "  $d not present, skipping"; continue; }
  kubectl -n kube-system patch deploy "$d" --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$CONTROL_NODE\"},\"tolerations\":[{\"key\":\"node-role.kubernetes.io/control-plane\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}]}}}}"
done
