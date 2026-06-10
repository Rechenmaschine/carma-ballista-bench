#!/usr/bin/env bash
# Same-cluster local-scan baseline for the S3 comparison: replicate the dataset
# to every worker (node-local scans), then run the concurrency sweep tagged
# `local_`. Run this AFTER the S3 sweep so staging's worker disk I/O doesn't
# perturb the S3 measurements. KS/REPS/QUERIES match the S3 passes for a clean A/B.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export KS="${KS:-1 2 3 5 10 15 20}" REPS="${REPS:-1 2 3}" QUERIES="${QUERIES:-1000}"

echo "## staging local-scan dataset to workers  $(date '+%F %T')"
"$here/stage.sh" || { echo "## DRIVER STOP: local-scan stage failed"; exit 1; }

echo "## local-scan sweep (NAME_PREFIX=local_)  KS={$KS} REPS={$REPS} Q=$QUERIES  $(date '+%F %T')"
NAME_PREFIX=local_ "$here/sweep.sh" || { echo "## DRIVER STOP: local-scan sweep failed"; exit 1; }
echo "## LOCAL-SCAN BASELINE DONE  $(date '+%F %T')"
