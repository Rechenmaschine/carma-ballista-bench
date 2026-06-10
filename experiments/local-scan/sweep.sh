#!/usr/bin/env bash
export EXPERIMENT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$EXPERIMENT_DIR/../../scripts/lib/sweep-core.sh" "$@"
