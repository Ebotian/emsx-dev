#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/.julia-depot"
export JULIA_DEPOT_PATH="$ROOT/.julia-depot:/usr/local/share/julia:/usr/share/julia"
export JULIA_LOAD_PATH='@:@stdlib'
export JULIA_PKG_OFFLINE='true'

exec julia \
  --startup-file=no \
  --history-file=no \
  --project="$ROOT" \
  "$@"
