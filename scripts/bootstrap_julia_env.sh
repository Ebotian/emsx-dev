#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Project.toml"
MANIFEST="$ROOT/Manifest.toml"
EMSX_PROJECT="$ROOT/EMSx.jl/Project.toml"

[[ -f "$PROJECT" ]] || { echo "missing root Project.toml" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "missing root Manifest.toml" >&2; exit 1; }
[[ -f "$EMSX_PROJECT" ]] || { echo "missing local EMSx.jl/Project.toml" >&2; exit 1; }

mkdir -p "$ROOT/.julia-depot"
export JULIA_DEPOT_PATH="$ROOT/.julia-depot:/usr/local/share/julia:/usr/share/julia"
export JULIA_LOAD_PATH='@:@stdlib'
export JULIA_PKG_OFFLINE='false'
export JULIA_PKG_PRECOMPILE_AUTO='0'

exec julia \
  --startup-file=no \
  --history-file=no \
  --project="$ROOT" \
  -e '
using Pkg
using TOML

VERSION == v"1.12.6" || error("bootstrap requires Julia 1.12.6; got $(VERSION)")
root = dirname(Base.active_project())
project = joinpath(root, "Project.toml")
manifest = joinpath(root, "Manifest.toml")
emsx_project = joinpath(root, "EMSx.jl", "Project.toml")
isfile(project) || error("missing root Project.toml")
isfile(manifest) || error("missing root Manifest.toml")
isfile(emsx_project) || error("missing local EMSx.jl/Project.toml")

lock = TOML.parsefile(manifest)
lock["julia_version"] == "1.12.6" || error("Manifest is not locked for Julia 1.12.6")
entries = lock["deps"]["EMSx"]
emsx = entries isa Vector ? only(entries) : entries
get(emsx, "path", nothing) == "EMSx.jl" || error("Manifest does not lock local EMSx")
manifest_before = read(manifest, String)

Pkg.instantiate()
Pkg.precompile()

read(manifest, String) == manifest_before || error("bootstrap must not rewrite Manifest.toml")
println("instantiated and precompiled locked root environment in $(DEPOT_PATH[1])")
'
