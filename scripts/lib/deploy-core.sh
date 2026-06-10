#!/usr/bin/env bash
# Generic deploy: wipe the namespace, render+apply this experiment's manifests,
# pin observability add-ons. Behaviour is identical across experiments; the
# manifest set ($MANIFESTS) and storage knobs come from experiment.env.
set -euo pipefail
. "$(dirname "$0")/common.sh"

echo ">> wiping namespace $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
echo ">> waiting for $NAMESPACE to terminate"
# python3, NOT jq: jq isn't on the nodes; a missing tool here once stranded the
# namespace in Terminating.
kubectl wait --for=delete namespace/"$NAMESPACE" --timeout=300s || {
  echo "!! namespace stuck terminating, clearing finalizers" >&2
  kubectl get ns "$NAMESPACE" -o json \
    | python3 -c 'import json,sys; o=json.load(sys.stdin); o["spec"]["finalizers"]=[]; print(json.dumps(o))' \
    | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f -
  kubectl wait --for=delete namespace/"$NAMESPACE" --timeout=120s
}

# Fresh trace file for the new scheduler (hostPath persists across pods).
echo ">> preparing trace dir $TRACE_DIR (on $CONTROL_NODE)"
mkdir -p "$TRACE_DIR" && chmod 777 "$TRACE_DIR" && : > "$TRACE_DIR/stages.jsonl"

echo ">> deploying ($STORAGE storage)"
render manifests/00-namespace.yaml.tmpl $MANIFESTS | kubectl apply -f -

# Optional storage-bandwidth cap: shape the MinIO pod's egress (aggregate read
# throughput). Applied as a patch so the no-shaping path needs no CNI plugin.
if [ "$STORAGE" = s3 ] && [ -n "${MINIO_EGRESS_BW:-}" ]; then
  echo ">> capping MinIO egress at $MINIO_EGRESS_BW (needs CNI bandwidth plugin)"
  kubectl -n "$NAMESPACE" patch deploy minio --type=merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubernetes.io/egress-bandwidth\":\"$MINIO_EGRESS_BW\"}}}}}"
fi

# Pin observability add-ons (dashboard + metrics-scraper) to the control node so
# workers stay executor-only and the dashboard survives worker flaps. Idempotent.
echo ">> pinning observability add-ons to $CONTROL_NODE"
for d in kubernetes-dashboard kubernetes-metrics-scraper; do
  kubectl -n kube-system get deploy "$d" >/dev/null 2>&1 || { echo "  $d not present, skipping"; continue; }
  kubectl -n kube-system patch deploy "$d" --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$CONTROL_NODE\"},\"tolerations\":[{\"key\":\"node-role.kubernetes.io/control-plane\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}]}}}}"
done
