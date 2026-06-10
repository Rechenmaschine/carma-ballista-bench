#!/usr/bin/env bash
# Compatibility shim -> experiments/local-scan/stage.sh.
# Experiments now live under experiments/<name>/ (see README). For the S3 variant
# run experiments/s3-central/stage.sh instead.
exec "$(dirname "$0")/../experiments/local-scan/stage.sh" "$@"
