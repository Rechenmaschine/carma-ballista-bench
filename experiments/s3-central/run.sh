#!/usr/bin/env bash
set -euo pipefail
export EXPERIMENT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$EXPERIMENT_DIR/../../scripts/lib/run-core.sh" "$@"
