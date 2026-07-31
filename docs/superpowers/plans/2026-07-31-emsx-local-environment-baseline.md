# EMSx Local Environment and Baseline Reproduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the exact local EMSx behavior required by the current experiments, lock all Julia dependencies in the repository root, separate the `wdwe2_k20` phases safely, and reproduce all 70 site scores within `1e-6` without modifying legacy artifacts.

**Architecture:** The repository root becomes the Julia application environment and uses the nested `EMSx.jl/` checkout as a relative path dependency. The existing numerical algorithm remains in `sdp_ar1_wdwe2.jl`; focused helper modules enforce environment identity, provenance, immutable run directories, and phase dispatch. Existing value functions are treated as read-only inputs, while a second acceptance run recalibrates them from scratch.

**Tech Stack:** Julia 1.12.6, EMSx.jl, StoOpt.jl, ControlVariables.jl, JLD2 0.4.55, CSV 0.10.16, DataFrames 1.8.2, TOML, SHA, Julia `Test`.

## Global Constraints

- Never edit `/home/ebt/.julia/packages`, the default Julia environment, or any file outside `/home/ebt/Downloads/emsx`.
- Do not overwrite or delete existing `results_sdp/sweep_wdwe2_k20` artifacts.
- Do not stage or commit the pre-existing `EMSx.jl/examples/sdp/function.jl` diff with unrelated changes.
- Before every `git add`/`git commit`, stop at the explicit commit gate and obtain separate user confirmation; never push.
- Every formal Julia process uses `--startup-file=no --history-file=no --project=<root>` and `JULIA_LOAD_PATH=@:@stdlib`.
- Baseline acceptance requires 70 unique sites, mean score `0.7676755785921663 ± 1e-6`, and every site score within `1e-6` of the captured legacy fixture.
- A run output directory must not exist before a new run; only an explicitly incomplete run with an identical configuration fingerprint may resume.
- Generated `Manifest.toml` content must come from Julia `Pkg`; do not hand-edit it.
- This is plan 1 of 4. Forecast alignment/rollout, MPC, and advanced-method/statistical-confirmation work belong to later plans after this plan passes.

---

## File Map

### Nested `EMSx.jl` repository

- Modify `EMSx.jl/Project.toml`: allow the CSV version used by the audited baseline.
- Modify `EMSx.jl/src/struct.jl`: restore `Result.control` and legacy-result conversion.
- Modify `EMSx.jl/src/simulate.jl`: record every applied control.
- Create `EMSx.jl/test/offline_local_behavior.jl`: network-free compatibility tests.
- Preserve separately `EMSx.jl/examples/sdp/function.jl`: pre-existing noise-layout diff.

### Outer experiment repository

- Modify `.gitignore`: track only the root lockfile.
- Create `Project.toml` and generated `Manifest.toml`: application environment.
- Create `scripts/julia_locked.sh`: only supported Julia launcher.
- Create `src/EnvironmentIdentity.jl` and `scripts/check_environment.jl`: main/worker package identity.
- Create `src/Provenance.jl`: hashes, Git state, machine identity, and manifests.
- Create `src/RunContract.jl`: immutable output reservation and phase status.
- Create `scripts/audit_sdp_helper.jl`: record the pre-existing nested diff without changing it.
- Create `scripts/capture_wdwe2_baseline.jl`: capture immutable legacy score/VF fixtures.
- Create `configs/wdwe2_k20.toml`: complete baseline configuration.
- Modify `sdp_ar1_wdwe2.jl`: phase selection and read-only VF source.
- Create `scripts/finalize_wdwe2_reproduction.jl`: compact acceptance report.
- Create focused tests under `test/`.

### Task dependencies

```text
Task 1 local EMSx compatibility
  -> Task 2 locked root environment
  -> Task 3 pre-existing helper audit
  -> Task 4 provenance and legacy fixtures
  -> Task 5 immutable phase runner
  -> Task 6 two-path 70-site reproduction
```

---

### Task 1: Rebuild the Local EMSx Compatibility Behavior

**Files:**
- Modify: `EMSx.jl/Project.toml:18-22`
- Modify: `EMSx.jl/src/struct.jl:12-17`
- Modify: `EMSx.jl/src/simulate.jl:109-111`
- Create: `EMSx.jl/test/offline_local_behavior.jl`
- Do not modify or stage: `EMSx.jl/examples/sdp/function.jl`

**Interfaces:**
- Produces: `EMSx.Result(horizon::Int64)` with `cost`, `soc`, and `control` vectors.
- Produces: `convert(EMSx.Result, legacy)` that fills missing controls with zeros.
- Produces: `EMSx.simulate_period(controller::EMSx.AbstractController, period::EMSx.Period, prices::EMSx.Prices)::EMSx.Simulation`, whose result records the controller output.
- Consumed by: every root experiment and the phase runner in Task 5.

- [ ] **Step 1: Write the offline failing test**

Create `EMSx.jl/test/offline_local_behavior.jl`:

```julia
using Test
using EMSx
using DataFrames
using TOML

struct FixedController <: EMSx.AbstractController
    value::Float64
end

EMSx.compute_control(
    controller::FixedController,
    information::EMSx.Information,
) = controller.value

struct LegacyResult
    cost::Vector{Float64}
    soc::Vector{Float64}
end

function synthetic_period(output_dir::String)
    data = DataFrame()
    for column in 1:197
        data[!, Symbol("column_$(column)")] = fill(Float64(column), 97)
    end
    rename!(
        data,
        :column_3 => :actual_consumption,
        :column_4 => :actual_pv,
    )

    battery = EMSx.Battery(10.0, 4.0, 0.95, 0.95)
    site = EMSx.Site("1", battery, nothing, nothing, output_dir)
    return EMSx.Period("1", data, site)
end

@testset "local EMSx compatibility" begin
    project = TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))
    @test occursin("0.10", project["compat"]["CSV"])

    result = EMSx.Result(3)
    @test result.cost == zeros(3)
    @test result.soc == zeros(3)
    @test result.control == zeros(3)

    legacy = LegacyResult([1.0, 2.0], [0.25, 0.5])
    migrated = convert(EMSx.Result, legacy)
    @test migrated.cost == legacy.cost
    @test migrated.soc == legacy.soc
    @test migrated.control == zeros(2)

    mktempdir() do output_dir
        period = synthetic_period(output_dir)
        prices = EMSx.Prices("test", ones(672), zeros(672))
        simulation = EMSx.simulate_period(
            FixedController(0.25),
            period,
            prices,
        )
        @test simulation.result.control == [0.25]
    end
end
```

- [ ] **Step 2: Resolve the package-local test environment and verify failure**

Run:

```bash
julia --startup-file=no --history-file=no --project=EMSx.jl -e '
using Pkg
Pkg.resolve()
Pkg.instantiate()
'
JULIA_LOAD_PATH='@:@stdlib' \
  julia --startup-file=no --history-file=no --project=EMSx.jl \
  EMSx.jl/test/offline_local_behavior.jl
```

Expected: test failure because CSV compat lacks 0.10 and `Result` has no `control` field. The ignored `EMSx.jl/Manifest.toml` may be generated here, but it is not a formal experiment lockfile.

- [ ] **Step 3: Apply the minimal local compatibility implementation**

In `EMSx.jl/Project.toml`, replace the CSV compat line with:

```toml
CSV = "0.9, 0.10"
```

In `EMSx.jl/src/struct.jl`, replace the existing `Result` definition and constructor with:

```julia
mutable struct Result
    cost::Array{Float64,1}
    soc::Array{Float64,1}
    control::Array{Float64,1}
end

Result(h::Int64) = Result(zeros(h), zeros(h), zeros(h))

Base.convert(::Type{Result}, x::Result) = x

function Base.convert(::Type{Result}, x)
    control = hasproperty(x, :control) ?
        getproperty(x, :control) :
        zeros(length(getproperty(x, :cost)))

    return Result(
        getproperty(x, :cost),
        getproperty(x, :soc),
        control,
    )
end
```

In `EMSx.jl/src/simulate.jl`, make the result assignment block exactly:

```julia
result.cost[t] = stage_cost
result.control[t] = control
result.soc[t] = state_of_charge
timer[t] = timing
```

- [ ] **Step 4: Resolve again and verify the offline test passes**

Run:

```bash
julia --startup-file=no --history-file=no --project=EMSx.jl -e '
using Pkg
Pkg.resolve()
Pkg.instantiate()
'
JULIA_LOAD_PATH='@:@stdlib' \
  julia --startup-file=no --history-file=no --project=EMSx.jl \
  EMSx.jl/test/offline_local_behavior.jl
```

Expected: all tests pass without network access.

- [ ] **Step 5: Verify the pre-existing helper diff remains isolated**

Run:

```bash
git -C EMSx.jl status --short
git -C EMSx.jl diff -- examples/sdp/function.jl
git -C EMSx.jl diff -- Project.toml src/struct.jl src/simulate.jl test/offline_local_behavior.jl
```

Expected: `examples/sdp/function.jl` remains a separate pre-existing diff; no file outside the four Task 1 paths changed except the ignored package-local Manifest.

- [ ] **Step 6: Commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git -C EMSx.jl add -- \
  Project.toml \
  src/struct.jl \
  src/simulate.jl \
  test/offline_local_behavior.jl
git -C EMSx.jl diff --cached --name-only
git -C EMSx.jl commit -m "fix: restore simulation control compatibility"
```

The cached path list must not contain `examples/sdp/function.jl`. Never push.

---

### Task 2: Create the Locked Root Julia Environment

**Files:**
- Modify: `.gitignore:16-19`
- Modify: `run_sweep.sh:1-35`
- Create: `Project.toml`
- Generate: `Manifest.toml`
- Create: `scripts/julia_locked.sh`
- Create: `src/EnvironmentIdentity.jl`
- Create: `scripts/check_environment.jl`
- Create: `test/runtests.jl`
- Create: `test/environment_identity.jl`

**Interfaces:**
- Produces: `EnvironmentIdentity.assert_environment!(root)::Nothing`.
- Produces: `EnvironmentIdentity.start_workers_checked!(root, count)::Vector{Int}`.
- Produces: `scripts/julia_locked.sh`, the only launcher used by later tasks.

- [ ] **Step 1: Write the environment identity test before creating the environment**

Create `test/runtests.jl`:

```julia
using Test

include("environment_identity.jl")
```

Create `test/environment_identity.jl`:

```julia
using Test
using TOML
using EMSx

const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "EnvironmentIdentity.jl"))
using .EnvironmentIdentity

@testset "locked root environment" begin
    @test isfile(joinpath(ROOT, "Project.toml"))
    @test isfile(joinpath(ROOT, "Manifest.toml"))
    @test LOAD_PATH == ["@", "@stdlib"]
    @test realpath(Base.active_project()) == realpath(joinpath(ROOT, "Project.toml"))
    @test realpath(pathof(EMSx)) == realpath(joinpath(ROOT, "EMSx.jl", "src", "EMSx.jl"))

    manifest = TOML.parsefile(joinpath(ROOT, "Manifest.toml"))
    @test manifest["julia_version"] == "1.12.6"
    entries = manifest["deps"]["EMSx"]
    entry = entries isa Vector ? only(entries) : entries
    @test entry["path"] == "EMSx.jl"
end
```

Expected initially: failure because root Project, Manifest, and module do not exist.

- [ ] **Step 2: Allow only the root Manifest to be tracked**

Replace `.gitignore` line 19 with:

```gitignore
# Package-local manifests stay ignored; the application lockfile is tracked.
**/Manifest.toml
!/Manifest.toml
```

- [ ] **Step 3: Create the root Project and generate the Manifest with Pkg**

Create `Project.toml` with the exact direct dependencies:

```toml
[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
Clustering = "aaaa29a8-35af-508c-8bc3-b662a17a0fe5"
ControlVariables = "6ab36c0b-7041-41d4-a72f-3fa204f20a75"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
Distributed = "8ba89e20-285c-5b6f-9357-94700520ee1b"
EMSx = "f2e99e64-6a52-11e9-34fb-57a45e766df1"
Interpolations = "a98d9a8b-a2ab-59e6-89dd-64a1c18fca59"
JLD2 = "033835bb-8acc-5ee8-8aae-3f567f8a3819"
LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
ProgressMeter = "92933f4c-e287-5a05-a399-4b506db050ca"
Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
SHA = "ea8e919c-243c-51af-8825-aaa63cd721ce"
Statistics = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
StoOpt = "b078af00-22e2-11e9-2e46-77c5cd6e0fea"
TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[compat]
julia = "=1.12.6"
CSV = "0.10.16"
DataFrames = "1.8.2"
JLD2 = "0.4.55"
```

Generate—not hand-edit—`Manifest.toml`:

```bash
JULIA_LOAD_PATH='@:@stdlib' \
  julia --startup-file=no --history-file=no --project=. -e '
using Pkg
@assert VERSION == v"1.12.6"
Pkg.develop(path="EMSx.jl")
Pkg.add(Pkg.PackageSpec(url="https://github.com/adrien-le-franc/ControlVariables.jl.git"))
Pkg.add(Pkg.PackageSpec(url="https://github.com/adrien-le-franc/StoOpt.jl.git"))
Pkg.resolve()
Pkg.instantiate()
Pkg.precompile()
'
```

Expected: Manifest reports Julia 1.12.6 and a relative `path = "EMSx.jl"` entry. If Pkg writes an absolute path or resolves a different incompatible package tree, stop and diagnose instead of editing the Manifest.

- [ ] **Step 4: Implement the locked launcher and identity checks**

Create executable `scripts/julia_locked.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JULIA_LOAD_PATH='@:@stdlib'

exec julia \
  --startup-file=no \
  --history-file=no \
  --project="$ROOT" \
  "$@"
```

Create `src/EnvironmentIdentity.jl`:

```julia
module EnvironmentIdentity

using Distributed
using EMSx
using TOML

export assert_environment!
export start_workers_checked!

function expected_emsx(root::String)
    return realpath(joinpath(root, "EMSx.jl", "src", "EMSx.jl"))
end

function assert_environment!(root::String)
    LOAD_PATH == ["@", "@stdlib"] ||
        error("JULIA_LOAD_PATH must be @:@stdlib; got $(LOAD_PATH)")
    realpath(Base.active_project()) == realpath(joinpath(root, "Project.toml")) ||
        error("wrong active Julia project")
    realpath(pathof(EMSx)) == expected_emsx(root) ||
        error("global EMSx fallback detected: $(pathof(EMSx))")

    manifest = TOML.parsefile(joinpath(root, "Manifest.toml"))
    manifest["julia_version"] == "1.12.6" || error("wrong Julia lock version")
    entries = manifest["deps"]["EMSx"]
    entry = entries isa Vector ? only(entries) : entries
    get(entry, "path", nothing) == "EMSx.jl" ||
        error("EMSx is not the relative local path dependency")
    return nothing
end

function start_workers_checked!(root::String, count::Int)
    count > 0 || error("worker count must be positive")
    nprocs() == 1 || error("start with no pre-existing workers")
    project = dirname(Base.active_project())
    addprocs(count; exeflags=`--startup-file=no --history-file=no --project=$project`)

    for worker in workers()
        identity = remotecall_fetch(worker) do
            @eval using EMSx
            (
                load_path=copy(LOAD_PATH),
                project=realpath(Base.active_project()),
                emsx=realpath(pathof(EMSx)),
            )
        end
        identity.load_path == ["@", "@stdlib"] || error("unsafe worker LOAD_PATH")
        identity.project == realpath(joinpath(root, "Project.toml")) ||
            error("worker uses wrong project")
        identity.emsx == expected_emsx(root) || error("worker uses non-local EMSx")
    end
    return workers()
end

end
```

Create `scripts/check_environment.jl`:

```julia
using EMSx
const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "EnvironmentIdentity.jl"))
using .EnvironmentIdentity

EnvironmentIdentity.assert_environment!(ROOT)
count = parse(Int, get(ENV, "N_WORKERS", "2"))
EnvironmentIdentity.start_workers_checked!(ROOT, count)
println("verified local EMSx for main process and $(count) workers")
```

- [ ] **Step 5: Route legacy sweep calls through the locked launcher**

In `run_sweep.sh`, define:

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$ROOT/sdp_ar1_param.jl"
JULIA_RUNNER="$ROOT/scripts/julia_locked.sh"
```

Replace every `julia "$SCRIPT"` invocation with:

```bash
"$JULIA_RUNNER" "$SCRIPT"
```

Do not run this legacy sweep during this plan.

- [ ] **Step 6: Verify identity and tests**

Run:

```bash
chmod +x scripts/julia_locked.sh
N_WORKERS=2 scripts/julia_locked.sh scripts/check_environment.jl
scripts/julia_locked.sh test/runtests.jl
git check-ignore -q Manifest.toml && exit 1 || true
```

Expected: main and both workers load `/home/ebt/Downloads/emsx/EMSx.jl/src/EMSx.jl`; tests pass; root Manifest is not ignored.

- [ ] **Step 7: Commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- .gitignore Project.toml Manifest.toml run_sweep.sh \
  scripts/julia_locked.sh scripts/check_environment.jl \
  src/EnvironmentIdentity.jl test/runtests.jl test/environment_identity.jl
git diff --cached --name-only
git commit -m "build: lock local Julia experiment environment"
```

Never push.

---

### Task 3: Audit the Pre-existing SDP Helper Diff Without Mixing It

**Files:**
- Preserve: `EMSx.jl/examples/sdp/function.jl:102-122`
- Create: `scripts/audit_sdp_helper.jl`
- Create: `audit/emsx-sdp-helper-preexisting.toml`
- Create: `test/sdp_helper_behavior.jl`

**Interfaces:**
- Produces: an immutable SHA-256 record of the exact pre-existing nested diff.
- Produces: an offline behavior test for `(cardinality, horizon)` noise layout and per-time probability normalization.

- [ ] **Step 1: Write the helper behavior test**

Create `test/sdp_helper_behavior.jl`:

```julia
using Test
using DataFrames
using Dates
using EMSx
using StoOpt

include(joinpath(@__DIR__, "..", "EMSx.jl", "examples", "sdp", "function.jl"))

function synthetic_law()
    timestamps = collect(Time(0):Minute(15):Time(23, 45))
    frame = DataFrame(
        timestamp=timestamps,
        value=[[Float64(index), Float64(index + 100)] for index in 1:96],
        probability=[[0.2, 0.2] for _ in 1:96],
    )
    return Dict("week_day" => frame, "week_end" => deepcopy(frame))
end

@testset "pre-existing SDP helper behavior" begin
    noises = data_frames_to_noises(synthetic_law())
    @test length(noises) == 672
    for time_index in 1:672
        variable = StoOpt.RandomVariable(noises, time_index)
        @test length(variable.support) == 2
        @test isapprox(sum(variable.probability), 1.0; atol=eps(Float64), rtol=0)
    end
end
```

Run:

```bash
scripts/julia_locked.sh test/sdp_helper_behavior.jl
```

Expected: pass on the current pre-existing dirty file. To demonstrate the test is meaningful without changing the working tree, run it against `git show HEAD:examples/sdp/function.jl` in a temporary copy; expected failure due layout or probability sum.

- [ ] **Step 2: Record the exact diff hash**

Create `scripts/audit_sdp_helper.jl`:

```julia
using SHA
using TOML
using Dates

const ROOT = normpath(joinpath(@__DIR__, ".."))
const EMSX_ROOT = joinpath(ROOT, "EMSx.jl")
const PATH = "examples/sdp/function.jl"
const OUTPUT = joinpath(ROOT, "audit", "emsx-sdp-helper-preexisting.toml")

diff = read(`git -C $EMSX_ROOT diff --binary -- $PATH`, String)
isempty(diff) && error("expected pre-existing helper diff is absent")
for fragment in ("w = collect(w')", "pw = collect(pw')", "pw[:, t] ./= sum(pw[:, t])")
    occursin(fragment, diff) || error("missing audited fragment: $(fragment)")
end

record = Dict(
    "schema_version" => 1,
    "captured_at_utc" => string(Dates.now(Dates.UTC)),
    "nested_head" => readchomp(`git -C $EMSX_ROOT rev-parse HEAD`),
    "path" => PATH,
    "diff_sha256" => bytes2hex(SHA.sha256(codeunits(diff))),
)
mkpath(dirname(OUTPUT))
if isfile(OUTPUT)
    existing = TOML.parsefile(OUTPUT)
    for key in ("schema_version", "nested_head", "path", "diff_sha256")
        existing[key] == record[key] || error("existing helper audit mismatch: $(key)")
    end
else
    open(OUTPUT, "w") do io
        TOML.print(io, record; sorted=true)
    end
end
```

Run twice and verify that the immutable audit file is byte-identical:

```bash
scripts/julia_locked.sh scripts/audit_sdp_helper.jl
cp audit/emsx-sdp-helper-preexisting.toml /tmp/emsx-helper-audit.toml
scripts/julia_locked.sh scripts/audit_sdp_helper.jl
diff -u /tmp/emsx-helper-audit.toml audit/emsx-sdp-helper-preexisting.toml
```

Expected: no diff. A changed nested HEAD or helper diff hash causes the second invocation to fail rather than overwrite the first record.

- [ ] **Step 3: Commit the outer audit only at its gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- scripts/audit_sdp_helper.jl \
  audit/emsx-sdp-helper-preexisting.toml test/sdp_helper_behavior.jl
git diff --cached --name-only
git commit -m "test: audit existing SDP noise layout fix"
```

Do not stage the nested helper yet. Never push.

- [ ] **Step 4: Independently gate the nested helper commit**

Recompute and compare the diff hash, rerun the behavior test, then stop for a second confirmation. Only after that separate confirmation:

```bash
git -C EMSx.jl add -- examples/sdp/function.jl
git -C EMSx.jl diff --cached --name-only
git -C EMSx.jl commit -m "fix: normalize SDP noise layout"
```

The cached list must contain exactly `examples/sdp/function.jl`. Never push.

---

### Task 4: Capture Provenance and Immutable Legacy Fixtures

**Files:**
- Create: `src/Provenance.jl`
- Create: `scripts/capture_wdwe2_baseline.jl`
- Create: `baselines/wdwe2_k20/input-manifest.tsv`
- Create: `baselines/wdwe2_k20/scores.csv`
- Create: `baselines/wdwe2_k20/vf-manifest.tsv`
- Create: `baselines/wdwe2_k20/legacy-source.toml`
- Create: `test/provenance.jl`
- Create: `test/wdwe2_baseline_fixture.jl`
- Modify: `test/runtests.jl`

**Interfaces:**
- Produces: `sha256_file(path::String)::String`.
- Produces: `git_state(repository::String)::NamedTuple`.
- Produces: `write_file_manifest(output::String, files::Vector{String}, root::String)::String`.
- Produces: `verify_file_manifest(manifest::String, root::String)::Nothing`.
- Produces: `assert_formal_sources_clean!(root::String)::Nothing`.
- Produces: `capture_provenance(output::String; root::String, phase::String, tag::String, run_id::String, parameters::Dict{String,Any}, input_manifest::String, vf_manifest::Union{Nothing,String})::Nothing`.
- Produces: immutable 70-site score and VF fixtures consumed by Tasks 5–6.

- [ ] **Step 1: Write hash and tamper-detection tests**

Create `test/provenance.jl` with a temporary `abc` file and assert:

```julia
@test Provenance.sha256_file(path) ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
```

Write a two-file manifest, verify it, mutate one byte, and assert `verify_file_manifest` throws. Also assert `git_state(ROOT)` and `git_state(joinpath(ROOT, "EMSx.jl"))` return SHA, dirty flag, and exact porcelain lines. In a temporary Git repository, assert `assert_formal_sources_clean!` passes when clean and throws after creating an untracked file. Capture provenance with zero workers and assert every key emitted below is present.

Expected initially: failure because `src/Provenance.jl` does not exist.

- [ ] **Step 2: Implement deterministic manifests and provenance**

Create `src/Provenance.jl` with:

```julia
module Provenance

using Dates
using Distributed
using EMSx
using LinearAlgebra
using SHA
using TOML

export sha256_file, git_state, write_file_manifest, verify_file_manifest
export assert_formal_sources_clean!, capture_provenance

sha256_file(path::String) = bytes2hex(open(SHA.sha256, path))

function git_state(repository::String)
    sha = readchomp(`git -C $repository rev-parse HEAD`)
    raw = read(`git -C $repository status --porcelain=v1 --untracked-files=all`, String)
    status = isempty(raw) ? String[] : split(chomp(raw), '\n')
    return (sha=sha, dirty=!isempty(status), status=status)
end

function write_file_manifest(output::String, files::Vector{String}, root::String)
    mkpath(dirname(output))
    open(output, "w") do io
        println(io, "path\tbytes\tsha256")
        for path in sort(files)
            isfile(path) || error("missing input: $(path)")
            println(io, "$(relpath(path, root))\t$(filesize(path))\t$(sha256_file(path))")
        end
    end
    return sha256_file(output)
end

function verify_file_manifest(manifest::String, root::String)
    lines = readlines(manifest)
    first(lines) == "path\tbytes\tsha256" || error("invalid manifest header")
    for line in Iterators.drop(lines, 1)
        relative, bytes, expected = split(line, '\t')
        path = joinpath(root, relative)
        isfile(path) || error("missing manifest input: $(relative)")
        filesize(path) == parse(Int, bytes) || error("size mismatch: $(relative)")
        sha256_file(path) == expected || error("hash mismatch: $(relative)")
    end
    return nothing
end

function assert_formal_sources_clean!(root::String)
    outer = git_state(root)
    nested = git_state(joinpath(root, "EMSx.jl"))
    outer.dirty && error("outer repository is dirty: $(outer.status)")
    nested.dirty && error("nested EMSx repository is dirty: $(nested.status)")
    return nothing
end

function capture_provenance(
    output::String;
    root::String,
    phase::String,
    tag::String,
    run_id::String,
    parameters::Dict{String,Any},
    input_manifest::String,
    vf_manifest::Union{Nothing,String}=nothing,
)
    ispath(output) && error("refusing to overwrite provenance: $(output)")
    outer = git_state(root)
    nested = git_state(joinpath(root, "EMSx.jl"))
    worker_identity = Dict{String,Any}[]
    for worker in workers()
        identity = remotecall_fetch(worker) do
            @eval using EMSx
            Dict(
                "worker" => myid(),
                "project" => Base.active_project(),
                "emsx" => pathof(EMSx),
                "load_path" => copy(LOAD_PATH),
            )
        end
        push!(worker_identity, identity)
    end

    record = Dict{String,Any}(
        "schema_version" => 1,
        "captured_at_utc" => string(Dates.now(Dates.UTC)),
        "phase" => phase,
        "tag" => tag,
        "run_id" => run_id,
        "julia_version" => string(VERSION),
        "cpu_name" => Sys.CPU_NAME,
        "cpu_threads" => Sys.CPU_THREADS,
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "blas_config" => sprint(show, LinearAlgebra.BLAS.get_config()),
        "active_project" => Base.active_project(),
        "emsx_path" => pathof(EMSx),
        "load_path" => copy(LOAD_PATH),
        "outer_git_sha" => outer.sha,
        "outer_git_dirty" => outer.dirty,
        "nested_git_sha" => nested.sha,
        "nested_git_dirty" => nested.dirty,
        "project_sha256" => sha256_file(joinpath(root, "Project.toml")),
        "manifest_sha256" => sha256_file(joinpath(root, "Manifest.toml")),
        "input_manifest" => relpath(input_manifest, root),
        "input_manifest_sha256" => sha256_file(input_manifest),
        "vf_manifest" => vf_manifest === nothing ? "" : relpath(vf_manifest, root),
        "vf_manifest_sha256" => vf_manifest === nothing ? "" : sha256_file(vf_manifest),
        "parameters" => parameters,
        "workers" => worker_identity,
    )
    mkpath(dirname(output))
    open(output, "w") do io
        TOML.print(io, record; sorted=true)
    end
    return nothing
end

end
```

- [ ] **Step 3: Capture the 144 formal input hashes**

The capture script must include:

- `dataset/train/{1..70}.csv.gz`;
- `dataset/test/{1..70}.csv.gz`;
- `dataset/metadata.csv`;
- `EMSx.jl/metadata/edf_prices.csv`;
- dummy and anticipative JLD2 baselines.

Run:

```bash
scripts/julia_locked.sh scripts/capture_wdwe2_baseline.jl
```

Expected: `input-manifest.tsv` contains 145 lines including its header. The script must refuse to overwrite an existing fixture unless every generated byte is identical.

- [ ] **Step 4: Capture legacy scores and value-function inventory**

In `scripts/capture_wdwe2_baseline.jl`, load:

```text
results_sdp/sweep_wdwe2_k20/score.jld2
results_sdp/sweep_wdwe2_k20/value_functions/{1..70}.jld2
```

Use `EMSx.evaluate_model`, sort sites numerically, and assert:

```julia
nrow(metrics) == 70
metrics.site == string.(1:70)
isapprox(mean(metrics.score), 0.7676755785921663; atol=1e-12, rtol=0)
```

For every VF JLD2, assert:

```julia
size(payload["value_function"]) == (673, 11, 20)
length(payload["alpha"]) == 672
length(payload["beta"]) == 672
```

Write `scores.csv` columns `site,cost,gain,score`; write `vf-manifest.tsv` columns `site,path,bytes,sha256,horizon,soc_points,z_points,alpha_length,beta_length,z_min,z_max`; write `legacy-source.toml` with score/log/VF fixture hashes and `legacy_environment_lock = "not_recorded_by_legacy_run"`.

- [ ] **Step 5: Verify fixtures and provenance tests**

Run:

```bash
scripts/julia_locked.sh test/provenance.jl
scripts/julia_locked.sh test/wdwe2_baseline_fixture.jl
```

Expected: 144 inputs, 70 scores, 70 VF rows, exact mean, exact shapes, and no writes under the legacy result directory.

- [ ] **Step 6: Commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/Provenance.jl scripts/capture_wdwe2_baseline.jl \
  baselines/wdwe2_k20/input-manifest.tsv \
  baselines/wdwe2_k20/scores.csv \
  baselines/wdwe2_k20/vf-manifest.tsv \
  baselines/wdwe2_k20/legacy-source.toml \
  test/provenance.jl test/wdwe2_baseline_fixture.jl test/runtests.jl
git diff --cached --name-only
git commit -m "test: capture wdwe2 baseline provenance"
```

Never stage `results_sdp/`; never push.

---

### Task 5: Separate Calibration, Simulation, and Evaluation Safely

**Files:**
- Create: `src/RunContract.jl`
- Create: `configs/wdwe2_k20.toml`
- Create: `test/run_contract.jl`
- Create: `test/wdwe2_phase_integration.jl`
- Modify: `test/runtests.jl`
- Modify: `sdp_ar1_wdwe2.jl:12-40,294-301,393-401,465-584`

**Interfaces (authoritative lease-scoped revision):**
- Produces: `RunContract.with_run_lock(path::String) do lease ... end`; the nonblocking filesystem lease owns the full reserve/work/cleanup/complete lifecycle and is released by close/crash.
- Produces only lease-scoped mutation: `RunContract.reserve_run!(lease, config::Dict; resume::Bool=false)::Symbol` and `RunContract.mark_complete!(lease, config::Dict; artifact_manifest::String)::Nothing`. Do not add path-only mutation overloads because they cannot prove exclusive ownership for the complete lifecycle.
- Produces read-only consumption validation: `RunContract.assert_complete!(path::String; phase::String)`, which validates the strict complete status, provenance hash, artifact-manifest hash, and every manifested artifact's path, byte count, SHA-256, non-symlink identity, and read stability.
- Produces strict status schemas: incomplete has exactly `schema_version,state,phase,fingerprint`; complete additionally has exactly `artifact_manifest,artifact_manifest_sha256,provenance_sha256`.
- Produces environment inputs `PHASE`, `RUN_ID`, optional exact-match `RUN_OUTPUT_DIR`, `VALUE_FUNCTION_SOURCE_DIR`, `VALUE_FUNCTION_MANIFEST`, and `SIMULATION_SOURCE_DIR`; an empty output override uses `<output_root>/<tag>/<run_id>/<phase>`.
- Produces independent `calibrate`, `simulate`, and `evaluate` phases with deterministic `artifacts.tsv`, atomic no-replace artifact publication, worker cleanup before completion, and `.emsx-task5-staging-<phase>` sibling staging outside the run tree.

- [ ] **Step 1: Write immutable-run contract tests**

Test all of these before implementation:

1. a missing run directory can be reserved;
2. an existing directory is rejected by default;
3. a complete directory can never resume;
4. an incomplete directory resumes only with identical config fingerprint;
5. `evaluate` rejects incomplete simulation input;
6. `simulate` rejects missing or hash-mismatched VF input;
7. TAG/RUN_ID path traversal such as `../legacy` is rejected.

Expected initially: failure because `src/RunContract.jl` does not exist.

- [ ] **Step 2: Implement the run contract**

Implement the contract around an unforgeable active lease registry; mutation APIs never accept a path by itself:

```julia
RunContract.with_run_lock(run_output) do lease
    reservation = RunContract.reserve_run!(lease, run_config; resume=resume)

    artifact_manifest = EnvironmentIdentity.with_workers_checked(ROOT, workers) do _
        ensure_phase_provenance!(run_config, reservation)
        run_phase_work!(reservation)
        ensure_artifact_manifest!(reservation)
    end

    verify_after_worker_cleanup!(run_config, artifact_manifest)
    RunContract.mark_complete!(
        lease,
        run_config;
        artifact_manifest=artifact_manifest,
    )
end

status = RunContract.assert_complete!(source_run; phase="simulate")
```

`reserve_run!` atomically publishes a strict incomplete directory with Linux `renameat2(RENAME_NOREPLACE)`. Status replacement, provenance output, manifest output, calibration VFs, per-site simulations, grouped score, and metrics are staged in the same-filesystem sibling namespace `.emsx-task5-staging-<phase>`, then installed by atomic rename or no-replace hardlink. A hard crash may leave uniquely named sibling residue, but never a temporary file inside `RUN_OUTPUT_DIR`; resume does not scan or broadly delete that sibling namespace.

`mark_complete!` validates every artifact row before atomically replacing status. `assert_complete!` repeats actual-artifact validation for consumers. Completion remains inside the active lease and occurs only after checked workers have been removed successfully.

- [ ] **Step 3: Add the complete baseline config**

Create `configs/wdwe2_k20.toml`:

```toml
schema_version = 1

[experiment]
controller = "wdwe2_periodic_ar1"
tag = "local_wdwe2_k20_locked_v1"
seed = 20260731
expected_sites = 70

[parameters]
dx = 0.1
du = 0.1
k_noise = 20
margin = 0.5
nz = 20
horizon = 672
max_vi_iters = 3
vi_tol = 0.001

[execution]
workers = 12
formal = true

[acceptance]
expected_mean_score = 0.7676755785921663
mean_atol = 1.0e-6
site_atol = 1.0e-6
```

- [ ] **Step 4: Make controller VF loading explicitly read-only**

Add a seventh field to `SdpAr1A2`:

```julia
value_function_source_dir::String
```

Replace its inner constructor with:

```julia
SdpAr1A2(value_function_source_dir::String="") =
    new(nothing, nothing, nothing, nothing, 0.0, 0.0, value_function_source_dir)
```

Preserve the source directory when site initialization rebuilds the controller:

```julia
function EMSx.initialize_site_controller(
    controller::SdpAr1A2,
    site::EMSx.Site,
    prices::EMSx.Prices,
)
    controller = SdpAr1A2(controller.value_function_source_dir)
    # Keep the existing AR fitting, grid, cost, dynamics, and model construction
    # below this line byte-for-byte unchanged.
```

Replace `load_value_functions` and its call with:

```julia
function load_value_functions(site_id::String, source_dir::String)
    isempty(source_dir) && error("VALUE_FUNCTION_SOURCE_DIR is required")
    path = joinpath(source_dir, site_id * ".jld2")
    isfile(path) || error("missing value function: $(path)")
    return JLD2.load(path)["value_function"]
end

function EMSx.compute_control(controller::SdpAr1A2, information::EMSx.Information)
    if information.t == 1
        controller.value_functions = load_value_functions(
            information.site_id,
            controller.value_function_source_dir,
        )
    end
    z_t = clamp(
        information.load[1] - information.pv[1],
        controller.z_min,
        controller.z_max,
    )
    control = StoOpt.compute_control(
        controller.model,
        information.t,
        [information.soc, z_t],
        StoOpt.RandomVariable(controller.model.noises, information.t),
        controller.value_functions,
    )
    return control[1]
end
```

- [ ] **Step 5: Reject calibration overwrites and preserve per-site simulations**

Before every calibration save:

```julia
output = joinpath(path_to_save_folder, "value_functions", site.id * ".jld2")
ispath(output) && error("refusing to overwrite value function: $(output)")
JLD2.save(
    output,
    Dict(
        "value_function" => vf,
        "time" => timer,
        "alpha" => ctrl.alpha,
        "beta" => ctrl.beta,
        "z_min" => ctrl.z_min,
        "z_max" => ctrl.z_max,
    ),
)
```

Do not use destructive `EMSx.group_all_simulations` in the new runner. Add:

```julia
function group_all_simulations_preserving!(sites::Vector{EMSx.Site})
    isempty(sites) && error("cannot group an empty site list")
    ids = sort(parse.(Int, getfield.(sites, :id)))
    length(unique(ids)) == length(ids) || error("duplicate site IDs")

    scores = Dict{String,Any}()
    for site in sites
        path = joinpath(site.path_to_save_folder, site.id * ".jld2")
        isfile(path) || error("missing simulation for site $(site.id)")
        scores[site.id] = JLD2.load(path, "simulations")
    end

    output = joinpath(first(sites).path_to_save_folder, "score.jld2")
    ispath(output) && error("refusing to overwrite grouped score: $(output)")
    JLD2.save(output, scores)
    return output
end
```

Replace the call to `EMSx.group_all_simulations(sites)` with `group_all_simulations_preserving!(sites)`. Formal evaluation separately asserts that the IDs are exactly `1:70`; one-site integration tests may group only site 1.

- [ ] **Step 6: Replace unconditional startup and `main()` with locked phase dispatch**

Before defining hyperparameter constants, load the committed config and helper modules:

```julia
using Distributed
using EMSx
using Statistics
using TOML

const ROOT = @__DIR__
include(joinpath(ROOT, "src", "EnvironmentIdentity.jl"))
include(joinpath(ROOT, "src", "Provenance.jl"))
include(joinpath(ROOT, "src", "RunContract.jl"))
using .EnvironmentIdentity
using .Provenance
using .RunContract

EnvironmentIdentity.assert_environment!(ROOT)

const CONFIG_PATH = get(
    ENV,
    "EXPERIMENT_CONFIG",
    joinpath(ROOT, "configs", "wdwe2_k20.toml"),
)
const CONFIG = TOML.parsefile(CONFIG_PATH)
const PARAMETERS = CONFIG["parameters"]
const EXECUTION = CONFIG["execution"]

const DX = Float64(PARAMETERS["dx"])
const DU = Float64(PARAMETERS["du"])
const K_NOISE = Int(PARAMETERS["k_noise"])
const MARGIN = Float64(PARAMETERS["margin"])
const NZ = Int(PARAMETERS["nz"])
const TAG = String(CONFIG["experiment"]["tag"])
const N_WORKERS = Int(EXECUTION["workers"])
const FORMAL_SETTING = get(EXECUTION, "formal", true)
FORMAL_SETTING isa Bool || error("execution.formal must be a Bool")
const FORMAL = FORMAL_SETTING

const PHASE = Symbol(get(ENV, "PHASE", ""))
const RUN_ID = get(ENV, "RUN_ID", "")
const RUN_OUTPUT_OVERRIDE = get(ENV, "RUN_OUTPUT_DIR", "")
const VALUE_FUNCTION_SOURCE_DIR = get(ENV, "VALUE_FUNCTION_SOURCE_DIR", "")
const VALUE_FUNCTION_MANIFEST = get(ENV, "VALUE_FUNCTION_MANIFEST", "")
const SIMULATION_SOURCE_DIR = get(ENV, "SIMULATION_SOURCE_DIR", "")

PHASE in (:calibrate, :simulate, :evaluate) ||
    error("PHASE must be calibrate, simulate, or evaluate")
RunContract.validate_component(TAG, "TAG")
RunContract.validate_component(RUN_ID, "RUN_ID")
FORMAL && Provenance.assert_formal_sources_clean!(ROOT)

const RUN_OUTPUT_DIR = normpath(joinpath(OUTPUT_ROOT, TAG, RUN_ID, String(PHASE)))
isempty(RUN_OUTPUT_OVERRIDE) ||
    normpath(abspath(RUN_OUTPUT_OVERRIDE)) == RUN_OUTPUT_DIR ||
    error("RUN_OUTPUT_DIR must equal the derived phase output")
const STAGING_NAMESPACE =
    joinpath(dirname(RUN_OUTPUT_DIR), ".emsx-task5-staging-$(basename(RUN_OUTPUT_DIR))")
```

Delete the old `EMSx.init_parallel` block; workers must start only inside `EnvironmentIdentity.with_workers_checked`. Build source identities before fingerprinting, then execute the entire mutable lifecycle under one lease:

```julia
function main()
    resume = get(ENV, "RESUME_INCOMPLETE", "false") == "true"
    RunContract.with_run_lock(RUN_OUTPUT_DIR) do lease
        sealed_vf = PHASE == :simulate ? capture_value_function_source() : nothing
        sealed_simulation = PHASE == :evaluate ? capture_simulation_source() : nothing
        run_config = build_run_config(sealed_vf, sealed_simulation)
        reservation = RunContract.reserve_run!(lease, run_config; resume=resume)

        artifact_manifest = EnvironmentIdentity.with_workers_checked(ROOT, N_WORKERS) do _
            ensure_phase_provenance!(run_config, reservation)
            run_selected_phase!(sealed_vf, sealed_simulation, reservation)
            ensure_artifact_manifest!(reservation)
        end

        verify_after_worker_cleanup!(
            run_config,
            sealed_vf,
            sealed_simulation,
            artifact_manifest,
        )
        RunContract.mark_complete!(
            lease,
            run_config;
            artifact_manifest=artifact_manifest,
        )
    end
    return nothing
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
```

Simulation accepts either the exact audited Task 4 legacy VF source or a strict complete `phase=calibrate` run; both source identities are included in the fingerprint. Evaluation accepts only a strict complete simulation source. Consumers verify every actual manifested artifact, not only manifest/provenance files. `evaluate_results` writes the current evaluation output only, and completion follows successful worker cleanup and final source/output revalidation.

- [ ] **Step 7: Run one-site integration tests**

Use temporary metadata containing only site 1 and development output directories. Assert independently:

- calibration creates only one valid `(673,11,20)` VF;
- simulation leaves the source VF hash and mtime unchanged;
- simulation records controls and retains its site JLD2;
- evaluation refuses incomplete simulation;
- a copied recalibrated `value_functions/1.jld2` payload changed without updating its manifest is rejected with an artifact hash mismatch and the consumer run remains incomplete;
- all status/provenance/artifact temporary files are outside `RUN_OUTPUT_DIR`, and an identifiable stale sibling staging residue neither enters the exact artifact set nor blocks an identical incomplete resume;
- rerunning any complete output path fails;
- no legacy result file changes.

Run:

```bash
scripts/julia_locked.sh test/run_contract.jl
scripts/julia_locked.sh test/wdwe2_phase_integration.jl
```

Expected: all tests pass.

- [ ] **Step 8: Commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/RunContract.jl configs/wdwe2_k20.toml \
  sdp_ar1_wdwe2.jl test/run_contract.jl \
  test/wdwe2_phase_integration.jl test/runtests.jl
git diff --cached --name-only
git commit -m "refactor: separate safe wdwe2 experiment phases"
```

Never push.

---

### Task 6: Reproduce the Baseline Through Both Acceptance Paths

**Files:**
- Create: `test/wdwe2_evaluation.jl`
- Create: `scripts/finalize_wdwe2_reproduction.jl`
- Generate: `baselines/wdwe2_k20/reproduction.toml`
- Generate: `baselines/wdwe2_k20/reproduced-scores.csv`
- Modify: `test/runtests.jl`
- Runtime only, ignored: `results_sdp/runs/local_wdwe2_k20_locked_v1/**`

**Interfaces:**
- Produces: independent site and mean regression assertions.
- Produces: compact, tracked acceptance evidence for both reused and recalibrated VF paths.

- [ ] **Step 1: Write evaluation tests against the immutable fixture**

Test these cases with DataFrames derived from `baselines/wdwe2_k20/scores.csv`:

- exactly sites `1:70` passes;
- one missing site fails;
- one duplicate site fails;
- one site changed by more than `1e-6` fails;
- two opposite site changes that cancel in the mean still fail;
- exact mean and all site differences within tolerance pass.

The production comparison must calculate:

```julia
mean_passed = isapprox(
    mean(actual.score),
    0.7676755785921663;
    atol=1e-6,
    rtol=0,
)
site_error = abs.(actual.score .- expected.score)
all_sites_passed = all(site_error .<= 1e-6)
```

- [ ] **Step 2: Run the full locked test suite before formal work**

Run:

```bash
scripts/julia_locked.sh scripts/check_environment.jl
scripts/julia_locked.sh test/runtests.jl
scripts/julia_locked.sh EMSx.jl/test/offline_local_behavior.jl
scripts/julia_locked.sh test/sdp_helper_behavior.jl
```

Expected: all pass; both repositories have the exact committed SHAs expected by provenance. If the required commit confirmations have not occurred, formal execution must stop rather than silently accept a dirty source tree.

- [ ] **Step 3: Formal path A—reuse the audited legacy VFs read-only**

Use unique, absent directories:

```bash
PHASE=simulate \
RUN_ID=reuse-existing-vf-v1 \
RUN_OUTPUT_DIR="$PWD/results_sdp/runs/local_wdwe2_k20_locked_v1/reuse-existing-vf-v1/simulate" \
VALUE_FUNCTION_SOURCE_DIR="$PWD/results_sdp/sweep_wdwe2_k20/value_functions" \
scripts/julia_locked.sh sdp_ar1_wdwe2.jl

PHASE=evaluate \
RUN_ID=reuse-existing-vf-v1 \
RUN_OUTPUT_DIR="$PWD/results_sdp/runs/local_wdwe2_k20_locked_v1/reuse-existing-vf-v1/evaluate" \
SIMULATION_SOURCE_DIR="$PWD/results_sdp/runs/local_wdwe2_k20_locked_v1/reuse-existing-vf-v1/simulate" \
scripts/julia_locked.sh sdp_ar1_wdwe2.jl
```

Acceptance: 70 sites; exact site set; mean and all site scores within `1e-6`; source VF hashes and mtimes unchanged; main and 12 workers load local EMSx.

- [ ] **Step 4: Formal path B—recalibrate and rerun all 70 sites**

Run:

```bash
PHASE=calibrate \
RUN_ID=recalibrated-v1 \
RUN_OUTPUT_DIR="$PWD/results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/calibrate" \
scripts/julia_locked.sh sdp_ar1_wdwe2.jl

PHASE=simulate \
RUN_ID=recalibrated-v1 \
RUN_OUTPUT_DIR="$PWD/results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/simulate" \
VALUE_FUNCTION_SOURCE_DIR="$PWD/results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/calibrate/value_functions" \
scripts/julia_locked.sh sdp_ar1_wdwe2.jl

PHASE=evaluate \
RUN_ID=recalibrated-v1 \
RUN_OUTPUT_DIR="$PWD/results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/evaluate" \
SIMULATION_SOURCE_DIR="$PWD/results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/simulate" \
scripts/julia_locked.sh sdp_ar1_wdwe2.jl
```

Acceptance is identical to path A. Passing path A but failing path B is not completion and must not lead to a relaxed tolerance.

- [ ] **Step 5: Generate compact acceptance evidence**

`scripts/finalize_wdwe2_reproduction.jl` must read both evaluation summaries, comparisons, provenance, and manifests; verify both passed; then create without overwriting:

- `baselines/wdwe2_k20/reproduction.toml` containing run IDs, hashes, actual means, tolerances, site count, and pass flags;
- `baselines/wdwe2_k20/reproduced-scores.csv` containing site, legacy score, reuse score, recalibrated score, and both absolute errors.

Run:

```bash
scripts/julia_locked.sh scripts/finalize_wdwe2_reproduction.jl
scripts/julia_locked.sh -e '
using TOML
report = TOML.parsefile("baselines/wdwe2_k20/reproduction.toml")
@assert report["site_count"] == 70
@assert report["reuse_existing_vf_passed"] == true
@assert report["recalibrated_passed"] == true
@assert isapprox(report["recalibrated_mean_score"], 0.7676755785921663; atol=1e-6, rtol=0)
'
```

- [ ] **Step 6: Verification-before-completion gate**

Run:

```bash
git status --short --branch
git -C EMSx.jl status --short --branch
git diff --check
git -C EMSx.jl diff --check
scripts/julia_locked.sh test/runtests.jl
```

Verify no legacy hash changed and no `results_sdp/` path is staged.

- [ ] **Step 7: Commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- test/wdwe2_evaluation.jl test/runtests.jl \
  scripts/finalize_wdwe2_reproduction.jl \
  baselines/wdwe2_k20/reproduction.toml \
  baselines/wdwe2_k20/reproduced-scores.csv
git diff --cached --name-only
git commit -m "test: verify locked wdwe2 baseline reproduction"
```

Never push.

---

## Plan 1 Completion Contract

This plan is complete only when:

- root `Manifest.toml` is tracked and generated by Julia 1.12.6;
- the Manifest uses relative local path `EMSx.jl`;
- main and all workers load the working-copy EMSx under sanitized `LOAD_PATH`;
- the three audited EMSx compatibility behaviors have offline tests;
- the pre-existing helper diff is independently hashed, tested, and handled only through its own confirmation gate;
- 144 formal inputs, 70 legacy scores, and 70 VFs have immutable hash inventories;
- calibration, simulation, and evaluation run independently into non-overwriting directories;
- simulation reads VFs without modifying them;
- reused-VF and recalibrated 70-site paths both pass the mean and every-site `1e-6` regressions;
- tracked compact evidence points to complete provenance for both runs;
- no global package, legacy result, dataset, or official scoring definition changed;
- no push occurred.

After this contract passes, write and execute plan 2 for align96, realtime Information semantics, forecast-error modeling, and correct one-step rollout.
