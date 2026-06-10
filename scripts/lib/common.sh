# Shared env + helpers for the experiment core scripts. Sourced, not run.
# Caller exports EXPERIMENT_DIR=experiments/<name> (the active experiment).
: "${EXPERIMENT_DIR:?export EXPERIMENT_DIR=experiments/<name> before sourcing}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# .env = global config, experiment.env = per-experiment overrides (STORAGE, manifests, S3 knobs).
set -a; . ./.env; . "$EXPERIMENT_DIR/experiment.env"; set +a

# envsubst whitelist: only these expand in manifests; $(POD_IP) etc. stay literal.
RENDER_VARS='$NAMESPACE $CONTROL_NODE $IMAGE_TAG $DATA_DIR $WORK_DIR $TRACE_DIR $TASK_SLOTS $EXEC_MEM_LIMIT $EXEC_MEM_POOL $MINIO_NODE $MINIO_PORT $MINIO_DATA_DIR $BUCKET $AWS_ENDPOINT $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY $AWS_REGION $AWS_ALLOW_HTTP'
render() { local t; for t in "$@"; do envsubst "$RENDER_VARS" < "$t"; echo ---; done; }
