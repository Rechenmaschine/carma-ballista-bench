#!/usr/bin/env bash
# Compatibility shim -> experiments/local-scan/deploy.sh (see README for the S3 variant).
exec "$(dirname "$0")/../experiments/local-scan/deploy.sh" "$@"
