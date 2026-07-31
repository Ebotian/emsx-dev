# EMSx Align96 与实时 Forecast Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变 EMSx 官方 split、成本函数和 score 定义的前提下，先锁定 legacy align96 单变量反事实，再实现 latest-origin `Information`、training-only forecast error、共享 `z_next` 的正确一步 rollout，并以不可覆盖的内部 blocked validation 证据预锁定唯一 70-site 确认候选。

**Architecture:** 外层仓库新增彼此独立的 forecast 对齐、pair/diagnostics、离散 error law、Bellman rollout、blocked validation、统计和 candidate-lock 模块；既有 `sdp_ar1_wdwe2.jl`、`sdp_ar1_a3.jl`、`sdp_ar1_a3rollout.jl` 保持只读，由可重现 renderer 生成两个新 runner，并继续消费 Task 5 lease-scoped `RunContract`。嵌套 `EMSx.jl` 只在 realtime 任务中对 `Information` 做一个最小行为修改，且该 nested commit 与所有 outer commits 分离。

**Tech Stack:** Julia `1.12.6`、本地 path dependency `EMSx.jl`、StoOpt、ControlVariables、CSV.jl、DataFrames.jl、JLD2、TOML、SHA、Dates、Statistics、Test；所有 Julia 命令经 `scripts/julia_locked.sh` 执行。

## Global Constraints

- Plan 1 Task 6 是硬前置：`baselines/wdwe2_k20/reproduction.toml` 与 `baselines/wdwe2_k20/reproduced-scores.csv` 必须存在，reuse 与 recalibrated 两路径均须通过 mean 和 70 个 site 的 `1e-6` regression；当前 `.superpowers/sdd/progress.md` 明确显示 Task 6 pending，因此执行本计划时必须先停在 Task 0。
- 任何实现或正式运行都不得改变 `EMSx.jl/src/database_interface/split_data.jl`、`EMSx.jl/src/function.jl`、官方 score 计算或 `configs/wdwe2_k20.toml`。
- 不修改 legacy scientific runners：`sdp_ar1_wdwe2.jl`、`sdp_ar1_a3.jl`、`sdp_ar1_a3rollout.jl`；新 runner 从其已审计文本机械生成，测试须证明只有 allowlisted replacement 生效。
- 不编辑全局 Julia package cache；不回退、不覆盖、不混入审计前已有 outer/nested dirty 修改。
- 除 Task 3 的 `EMSx.jl/src/struct.jl:114-124` 外，不修改任何 nested EMSx 现有源码；`EMSx.jl/examples/sdp/function.jl` 的 pre-existing diff 始终只读。
- 每次 `git add`/`git commit` 前必须单独取得用户确认；确认一次只覆盖紧随其后的一个 commit；不执行 `git push`。
- 所有正式 output 使用 `<output_root>/<tag>/<run_id>/<phase>`，运行前必须不存在；继续使用 `RunContract.with_run_lock`、`reserve_run!`、`mark_complete!`、`assert_complete!`，不得新增 path-only mutation API。
- 永不覆盖 `results_sdp/sweep_wdwe2_k20/**`、`results_sdp/sweep_wdwe2_k20.log`、`baselines/wdwe2_k20/**` 或任何 complete run；simulation 必须显式传入 VF source 与 manifest 并在前后验证 hash。
- 模型选择只读 `dataset/train/**`、`dataset/metadata.csv`、prices、锁定环境和只读 VF；blocked validation 进程不得打开 `dataset/test/**`，测试必须用 path-open spy 证明这一点。
- Forecast 列映射固定为 `k=1..96` 对应 suffix `00..95`；误差固定为 `actual_net[t+k] - forecast_net_issued_at_t[k]`，不能把 AR innovation 改名为 forecast error。
- 内部 validation 使用固定 `seed = 20260731`、连续 15 分钟时间块、固定候选集合和固定 tie-break；official test score 不参与候选选择。
- align96 必须在 realtime nested change 之前以 legacy EMSx SHA 单独 pre-lock、单独 TAG 运行；其唯一科学变量是 oldest-origin forecast index `[1] -> [96]`，不修正 error law 或 shared-`z_next`。
- 最终 realtime candidate 必须在 official 70-site 运行前写入不可覆盖 candidate specification；本计划到 pre-lock 后设置显式 STOP gate，70-site confirmation 命令只记录、不在 pre-lock task 中执行。
- Git 只跟踪代码、配置、hash inventory、candidate spec 和紧凑统计；不跟踪 JLD2、逐步轨迹或 `results_sdp/**` 大文件。

## File/Interface Map

- `src/ForecastAlignment.jl`：纯函数定义 legacy `[96]` 与 realtime `[1]` 净预测语义。
- `scripts/render_align96_runner.jl`、`sdp_align96.jl`：从只读 `sdp_ar1_wdwe2.jl` 机械生成 align96 runner；renderer 的 byte equality test 是单变量审计边界。
- `configs/align96_wdwe2_k20.toml`：独立 controller/TAG；数值参数与 locked wdwe2 config 完全相同。
- `EMSx.jl/test/information.jl`、`EMSx.jl/src/struct.jl`：encoded timestamp oracle 与唯一 nested realtime 行为修改。
- `src/ForecastPairs.jl`：按 timestamp join 生成 training-only horizon pairs 和 RMSE/bias/coverage/tail diagnostics。
- `src/ForecastErrorLaw.jl`：quarter-of-day × weekday/weekend 的 deterministic weighted quantization 与 global shrink。
- `src/RealtimeRollout.jl`：枚举控制与 error realizations，一次计算共享的 clamped `z_next`，同时送入 stage cost 和 `h[t+1]`。
- `scripts/render_realtime_rollout_runner.jl`、`sdp_realtime_rollout.jl`、`configs/realtime_rollout_k20.toml`：新 realtime runner；不修改 baseline runner。
- `src/BlockedValidation.jl`、`scripts/run_blocked_validation.jl`、`configs/realtime_rollout_validation.toml`：只用 train 的 prefix-fit/next-block validation 和固定候选选择。
- `src/CandidateStatistics.jl`：70-site exact-set、fixed-seed clustered/paired bootstrap 与三项 hard endpoint。
- `src/CandidateLock.jl`、`scripts/lock_forecast_candidate.jl`：不可覆盖 candidate spec、输入 hash 与 pre-lock integrity。
- `test/*.jl`：每个 outer 模块一个 focused test；`test/runtests.jl` 只追加已完成 task 的 focused test。

---

### Task 0: Enforce the Plan 1 Task 6 Prerequisite

**Files:**
- Read-only: `.superpowers/sdd/progress.md`
- Read-only: `.superpowers/sdd/task-6-report.md`
- Read-only: `baselines/wdwe2_k20/reproduction.toml`
- Read-only: `baselines/wdwe2_k20/reproduced-scores.csv`
- Read-only: `results_sdp/sweep_wdwe2_k20/**`

**Interfaces:**
- Consumes: Task 5 `RunContract.assert_complete!(path::String; phase::String)` and Task 6 compact evidence schema.
- Produces: a binary go/no-go decision; this task creates no files and has no commit.

- [ ] **Step 1: Verify the documented Task 6 state before touching code**

Run:

```bash
test -f baselines/wdwe2_k20/reproduction.toml
test -f baselines/wdwe2_k20/reproduced-scores.csv
scripts/julia_locked.sh -e '
using TOML
report = TOML.parsefile("baselines/wdwe2_k20/reproduction.toml")
@assert report["site_count"] == 70
@assert report["reuse_existing_vf_passed"] == true
@assert report["recalibrated_passed"] == true
@assert report["mean_atol"] == 1e-6
@assert report["site_atol"] == 1e-6
@assert isapprox(report["recalibrated_mean_score"], 0.7676755785921663; atol=1e-6, rtol=0)
'
```

Expected now: STOP because both compact evidence files are absent and Task 6 is pending. Expected after Plan 1 completion: exit 0 with all assertions true.

- [ ] **Step 2: Run the complete locked preflight after evidence exists**

Run:

```bash
scripts/julia_locked.sh scripts/check_environment.jl
scripts/julia_locked.sh test/runtests.jl
scripts/julia_locked.sh EMSx.jl/test/offline_local_behavior.jl
scripts/julia_locked.sh test/sdp_helper_behavior.jl
git status --short --branch
git -C EMSx.jl status --short --branch
```

Expected: all test commands pass; formal source SHAs are the committed Task 6 SHAs; no legacy/data/result path changed. If either repository is dirty at the formal gate, stop rather than weakening `Provenance.assert_formal_sources_clean!`.

- [ ] **Step 3: Snapshot legacy assets before candidate work**

Run:

```bash
scripts/julia_locked.sh -e '
include("src/Provenance.jl")
using .Provenance
for path in (
    "results_sdp/sweep_wdwe2_k20/score.jld2",
    "results_sdp/sweep_wdwe2_k20.log",
    "baselines/wdwe2_k20/vf-manifest.tsv",
    "baselines/wdwe2_k20/reproduction.toml",
    "baselines/wdwe2_k20/reproduced-scores.csv",
)
    println(path, "\t", Provenance.sha256_file(path))
end
'
```

Expected: five lowercase SHA-256 values. Preserve this terminal evidence for every later no-overwrite review; do not write a duplicate baseline file.

---

### Task 1: Build the Legacy Align96 Single-Variable Candidate

**Files:**
- Create: `src/ForecastAlignment.jl`
- Create: `scripts/render_align96_runner.jl`
- Create: `sdp_align96.jl`
- Create: `configs/align96_wdwe2_k20.toml`
- Create: `test/legacy_align96.jl`
- Modify: `test/runtests.jl:10`
- Read-only oracle: `sdp_ar1_wdwe2.jl:1-2078`
- Read-only oracle: `sdp_ar1_a3rollout.jl:397-438`

**Interfaces:**
- Consumes: legacy `EMSx.Information` whose forecast comes from the oldest row in `t+1:t+96`; audited wdwe2 VF source and Task 5 phase contract.
- Produces: `ForecastAlignment.forecast_net(load::AbstractVector, pv::AbstractVector, horizon::Integer)::Float64`.
- Produces: `ForecastAlignment.legacy_align96_net(information::EMSx.Information)::Float64`, fixed to horizon 96.
- Produces: `ForecastAlignment.realtime_one_step_net(information::EMSx.Information)::Float64`, fixed to horizon 1 for later tasks.
- Produces: a byte-reproducible `sdp_align96.jl` whose only scientific change is the stage-cost baseline `forecast_[1] -> forecast_[96]`; continuation remains legacy AR dynamics by design.

- [ ] **Step 1: Write failing alignment and renderer tests**

Create `test/legacy_align96.jl` with an encoded `EMSx.Information` constructed directly through its field constructor and these assertions:

```julia
using EMSx
using Test

const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "ForecastAlignment.jl"))
include(joinpath(ROOT, "scripts", "render_align96_runner.jl"))
using .ForecastAlignment

@testset "legacy align96 is one variable" begin
    prices = EMSx.Prices("encoded", ones(672), zeros(672))
    battery = EMSx.Battery(10.0, 4.0, 0.95, 0.95)
    information = EMSx.Information(
        1,
        0.25,
        [97.0, 96.0],
        collect(2001.0:2096.0),
        [197.0, 196.0],
        collect(3001.0:3096.0),
        prices,
        battery,
        "1",
    )
    @test forecast_net(information.forecast_load, information.forecast_pv, 96) == 1000.0
    @test legacy_align96_net(information) == 1000.0
    @test realtime_one_step_net(information) == 1000.0
    @test_throws BoundsError forecast_net([1.0], [0.0], 96)

    baseline = read(joinpath(ROOT, "sdp_ar1_wdwe2.jl"), String)
    rendered = render_align96_runner(baseline)
    @test rendered == read(joinpath(ROOT, "sdp_align96.jl"), String)
    @test render_align96_runner(baseline) == rendered
    @test_throws ErrorException render_align96_runner(replace(baseline, "forecast-control insertion point" => "missing"))
end
```

The direct values deliberately make `[1]` and `[96]` have the same net only in this first smoke assertion; add a second assertion with `forecast_load = collect(1.0:96.0)` and zero PV so `legacy_align96_net == 96.0` and `realtime_one_step_net == 1.0`.

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
scripts/julia_locked.sh test/legacy_align96.jl
```

Expected: FAIL because `src/ForecastAlignment.jl` and renderer output do not exist.

- [ ] **Step 3: Implement the pure alignment API**

Create `src/ForecastAlignment.jl`:

```julia
module ForecastAlignment

export forecast_net, legacy_align96_net, realtime_one_step_net

function forecast_net(
    load::AbstractVector,
    pv::AbstractVector,
    horizon::Integer,
)::Float64
    length(load) == length(pv) || error("forecast load/PV length mismatch")
    1 <= horizon <= length(load) || throw(BoundsError(load, horizon))
    return Float64(load[horizon] - pv[horizon])
end

legacy_align96_net(information)::Float64 =
    forecast_net(information.forecast_load, information.forecast_pv, 96)

realtime_one_step_net(information)::Float64 =
    forecast_net(information.forecast_load, information.forecast_pv, 1)

end
```

- [ ] **Step 4: Create the locked align96 config without changing baseline parameters**

Create `configs/align96_wdwe2_k20.toml` with this exact content:

```toml
schema_version = 1

[experiment]
controller = "legacy_align96_stage_only_wdwe2"
tag = "legacy_align96_wdwe2_k20_locked_v1"
seed = 20260731
expected_sites = 70
candidate_spec = "candidates/align96_v1/candidate.toml"

[parameters]
dx = 0.1
du = 0.1
k_noise = 20
margin = 0.5
nz = 20
horizon = 672
max_vi_iters = 3
vi_tol = 0.001
forecast_index = 96
rollout_semantics = "legacy_stage_only_ar_continuation"

[execution]
workers = 12
formal = true

[inputs]
input_manifest = "baselines/wdwe2_k20/input-manifest.tsv"
prices = "EMSx.jl/metadata/edf_prices.csv"
metadata = "dataset/metadata.csv"
train = "dataset/train"
test = "dataset/test"

[acceptance]
expected_sites = 70
```

Test `TOML.parsefile` and assert that all wdwe2 numerical parameter values are identical to `configs/wdwe2_k20.toml`; only `forecast_index` and the descriptive `rollout_semantics` are additional scientific settings.

- [ ] **Step 5: Implement deterministic runner rendering**

Create `scripts/render_align96_runner.jl` as a module/function that:

1. requires each source replacement string to occur exactly once;
2. changes the banner and default config path to `configs/align96_wdwe2_k20.toml`;
3. inserts `include(joinpath($ROOT, "src", "ForecastAlignment.jl")); using .ForecastAlignment` inside `PHASE_CODE`;
4. replaces only `EMSx.compute_control(controller::SdpAr1A2, information::EMSx.Information)` at `sdp_ar1_wdwe2.jl:667-690` with the following legacy stage-only method;
5. requires `parameters.forecast_index == 96` and records `candidate_spec` hash in `build_run_config`.

Use this exact method body in the replacement:

```julia
function EMSx.compute_control(controller::SdpAr1A2, information::EMSx.Information)
    if information.t == 1
        controller.value_functions = load_value_functions(
            information.site_id,
            controller.value_function_source_dir,
            controller.value_function_snapshot,
            controller.value_function_entries,
            controller.value_function_guards,
        )
    end
    z_t = clamp(
        information.load[1] - information.pv[1],
        controller.z_min,
        controller.z_max,
    )
    b_t = ForecastAlignment.legacy_align96_net(information)
    original_cost = controller.model.cost
    buy = information.prices.buy
    sell = information.prices.sell
    power = information.battery.power
    function align96_cost(
        t::Int64,
        state::Array{Float64,1},
        control::Array{Float64,1},
        noise::Array{Float64,1},
    )
        z_stage = b_t + noise[1]
        control_kwh = control[1] * power * 0.25
        imported_energy = control_kwh + z_stage
        return buy[t] * max(0.0, imported_energy) -
               sell[t] * max(0.0, -imported_energy)
    end
    try
        controller.model.cost = align96_cost
        control = StoOpt.compute_control(
            controller.model,
            information.t,
            [information.soc, z_t],
            StoOpt.RandomVariable(controller.model.noises, information.t),
            controller.value_functions,
        )
        return control[1]
    finally
        controller.model.cost = original_cost
    end
end
```

The renderer must fail unless the source contains the exact baseline method block once, and must assert the rendered text still contains the original baseline dynamics formula `alpha[t] * state[2] + beta[t] + noise[1]`. Generate `sdp_align96.jl` once with:

```bash
scripts/julia_locked.sh scripts/render_align96_runner.jl \
  sdp_ar1_wdwe2.jl sdp_align96.jl
```

Expected: `sdp_align96.jl` is created; a second invocation refuses to overwrite it. The test calls `render_align96_runner` in memory and proves byte equality.

- [ ] **Step 6: Test fail-closed and no-overwrite behavior on one synthetic site**

Extend `test/legacy_align96.jl` to create a one-site development config under `mktempdir` with `expected_sites = 1`, `workers = 1`, `formal = false`, a unique `development.output_root`, and a temporary candidate spec. Launch only `PHASE=simulate` with copied one-site VF and manifest fixtures. Assert:

```julia
@test success(first_run)
@test !success(second_run)
@test occursin("refusing", second_stderr) || occursin("complete", second_stderr)
@test source_vf_sha_after == source_vf_sha_before
@test isfile(joinpath(output, "status.toml"))
@test RunContract.assert_complete!(output; phase="simulate")["state"] == "complete"
```

Also assert an align96 process refuses to start when `forecast_index != 96`, candidate spec hash mismatches, or nested EMSx SHA differs from the candidate spec.

- [ ] **Step 7: Run focused and regression tests**

Run:

```bash
scripts/julia_locked.sh test/legacy_align96.jl
scripts/julia_locked.sh test/run_contract.jl
scripts/julia_locked.sh test/wdwe2_phase_integration.jl
scripts/julia_locked.sh test/runtests.jl
git diff --check
```

Expected: all pass; renderer equality proves the read-only baseline runner was not edited; legacy snapshots remain unchanged.

- [ ] **Step 8: Outer commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/ForecastAlignment.jl scripts/render_align96_runner.jl \
  sdp_align96.jl configs/align96_wdwe2_k20.toml \
  test/legacy_align96.jl test/runtests.jl
git diff --cached --name-only
git commit -m "feat: add locked legacy align96 counterfactual"
```

Expected staged set: exactly the six listed paths. Never stage `results_sdp/`; never push.

---

### Task 2: Pre-lock and Run Align96 Before Realtime Semantics Change

**Files:**
- Create: `src/CandidateLock.jl`
- Create: `scripts/lock_forecast_candidate.jl`
- Create: `test/candidate_lock.jl`
- Generate once: `candidates/align96_v1/candidate.toml`
- Modify: `test/runtests.jl`
- Runtime only, ignored: `results_sdp/runs/legacy_align96_wdwe2_k20_locked_v1/align96-official-v1/**`

**Interfaces:**
- Consumes: clean committed outer Task 1 SHA, unchanged legacy nested EMSx SHA, Plan 1 compact evidence, config/runner/VF manifest hashes.
- Produces: `CandidateLock.write_candidate_spec!(path::String, record::Dict)::String`, returning the SHA-256 of a newly published file and refusing any existing target.
- Produces: `CandidateLock.assert_candidate_spec!(path::String; root::String, expected_name::String)::Dict{String,Any}`.
- Produces: immutable align96 identity before any official run.

- [ ] **Step 1: Write failing candidate-lock tests**

Create `test/candidate_lock.jl` covering exact schema, lowercase 64-hex hashes, path containment, symlink rejection, missing referenced input, hash mismatch, candidate name mismatch, second-write refusal, and mutation-after-read detection. The passing record must contain exactly:

```julia
Dict{String,Any}(
    "schema_version" => 1,
    "candidate_name" => "align96_v1",
    "implementation_outer_sha" => repeat("a", 40),
    "nested_emsx_sha" => repeat("b", 40),
    "runner_path" => "sdp_align96.jl",
    "runner_sha256" => repeat("c", 64),
    "config_path" => "configs/align96_wdwe2_k20.toml",
    "config_sha256" => repeat("d", 64),
    "manifest_sha256" => repeat("e", 64),
    "vf_manifest_path" => "baselines/wdwe2_k20/vf-manifest.tsv",
    "vf_manifest_sha256" => repeat("f", 64),
    "baseline_reproduction_path" => "baselines/wdwe2_k20/reproduction.toml",
    "baseline_reproduction_sha256" => repeat("1", 64),
    "seed" => 20260731,
    "tag" => "legacy_align96_wdwe2_k20_locked_v1",
    "run_id" => "align96-official-v1",
    "forecast_origin" => "legacy_oldest_visible",
    "forecast_horizon" => 96,
    "rollout_semantics" => "legacy_stage_only_ar_continuation",
    "expected_sites" => 70,
    "failure_rule" => "any incomplete site, provenance mismatch, or non-finite metric fails",
)
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
scripts/julia_locked.sh test/candidate_lock.jl
```

Expected: FAIL because `src/CandidateLock.jl` does not exist.

- [ ] **Step 3: Implement atomic no-replace candidate locking**

Implement `CandidateLock` with these rules:

```julia
const SHA1 = r"^[0-9a-f]{40}$"
const SHA256 = r"^[0-9a-f]{64}$"
const REQUIRED_KEYS = Set((
    "schema_version", "candidate_name", "implementation_outer_sha",
    "nested_emsx_sha", "runner_path", "runner_sha256", "config_path",
    "config_sha256", "manifest_sha256", "vf_manifest_path",
    "vf_manifest_sha256", "baseline_reproduction_path",
    "baseline_reproduction_sha256", "seed", "tag", "run_id",
    "forecast_origin", "forecast_horizon", "rollout_semantics",
    "expected_sites", "failure_rule",
))
```

`write_candidate_spec!` writes sorted TOML into a sibling `mktemp`, fsyncs and closes it, then uses `Base.Filesystem.hardlink(temporary, path)` so existing targets fail atomically; it removes only its own temporary in `finally`. `assert_candidate_spec!` reads bytes once, validates the exact key set and every referenced file/hash, then re-reads and requires identical bytes before returning.

- [ ] **Step 4: Generate the align96 candidate spec before the nested change**

Run only after Task 1 commit and clean-source checks:

```bash
scripts/julia_locked.sh scripts/lock_forecast_candidate.jl \
  --name align96_v1 \
  --runner sdp_align96.jl \
  --config configs/align96_wdwe2_k20.toml \
  --tag legacy_align96_wdwe2_k20_locked_v1 \
  --run-id align96-official-v1 \
  --origin legacy_oldest_visible \
  --horizon 96 \
  --semantics legacy_stage_only_ar_continuation \
  --output candidates/align96_v1/candidate.toml
```

Expected: creates exactly one TOML file; captures current outer HEAD as `implementation_outer_sha`, current nested HEAD, Manifest/config/runner/VF/baseline evidence hashes; a second invocation fails without changing bytes or mtime.

- [ ] **Step 5: Run focused tests and commit the lock separately**

Run:

```bash
scripts/julia_locked.sh test/candidate_lock.jl
scripts/julia_locked.sh test/legacy_align96.jl
scripts/julia_locked.sh -e '
include("src/CandidateLock.jl")
using .CandidateLock
assert_candidate_spec!(
    "candidates/align96_v1/candidate.toml";
    root=pwd(),
    expected_name="align96_v1",
)
'
git diff --check
```

Expected: all pass.

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/CandidateLock.jl scripts/lock_forecast_candidate.jl \
  test/candidate_lock.jl test/runtests.jl \
  candidates/align96_v1/candidate.toml
git diff --cached --name-only
git commit -m "test: prelock align96 candidate identity"
```

Never push.

- [ ] **Step 6: Execute the one pre-specified align96 official diagnostic before Task 3**

This step is permitted only after a separate explicit user instruction to start the pre-locked 70-site run. Do not infer permission from commit approval.

Run into the unique absent path:

```bash
EXPERIMENT_CONFIG="$PWD/configs/align96_wdwe2_k20.toml" \
CANDIDATE_SPEC="$PWD/candidates/align96_v1/candidate.toml" \
PHASE=simulate \
RUN_ID=align96-official-v1 \
VALUE_FUNCTION_SOURCE_DIR="$PWD/results_sdp/sweep_wdwe2_k20/value_functions" \
VALUE_FUNCTION_MANIFEST="$PWD/baselines/wdwe2_k20/vf-manifest.tsv" \
scripts/julia_locked.sh sdp_align96.jl

EXPERIMENT_CONFIG="$PWD/configs/align96_wdwe2_k20.toml" \
CANDIDATE_SPEC="$PWD/candidates/align96_v1/candidate.toml" \
PHASE=evaluate \
RUN_ID=align96-official-v1 \
SIMULATION_SOURCE_DIR="$PWD/results_sdp/runs/legacy_align96_wdwe2_k20_locked_v1/align96-official-v1/simulate" \
scripts/julia_locked.sh sdp_align96.jl
```

Expected: strict complete simulation contains 70 site JLD2 files plus `score.jld2`; strict complete evaluation contains `metrics.csv`; source VF manifest/hashes/mtimes and all legacy hashes are unchanged. The observed score is diagnostic evidence only and must not choose realtime hyperparameters.

- [ ] **Step 7: Gate the nested transition**

Run:

```bash
scripts/julia_locked.sh -e '
include("src/RunContract.jl")
using .RunContract
assert_complete!(
    "results_sdp/runs/legacy_align96_wdwe2_k20_locked_v1/align96-official-v1/simulate";
    phase="simulate",
)
assert_complete!(
    "results_sdp/runs/legacy_align96_wdwe2_k20_locked_v1/align96-official-v1/evaluate";
    phase="evaluate",
)
'
```

Expected: both pass. Do not begin Task 3 until this gate passes, because after realtime `Information` the align96 single-variable semantics no longer exist in the active nested checkout.

---

### Task 3: Encode Timestamp Semantics and Switch `Information` to Latest Origin

**Files:**
- Create: `EMSx.jl/test/information.jl`
- Modify: `EMSx.jl/src/struct.jl:114-124`
- Read-only: `EMSx.jl/src/simulate.jl:91-136`

**Interfaces:**
- Consumes: `Information(t::Int64, prices::Prices, period::Period, soc::Float64)` and `apply_control(t, horizon, prices, period, soc, control)`.
- Produces: unchanged `EMSx.Information` field shape; `load`/`pv` remain latest-to-oldest history, while `forecast_load`/`forecast_pv` come from the latest visible origin row.
- Produces: offline encoded oracle for `t=1`, middle step, and final simulator step.

- [ ] **Step 1: Write the failing encoded timestamp test**

Create a 100-row DataFrame whose columns are named exactly as EMSx input. Use:

```julia
encoded(origin::Int, horizon::Int) = origin * 1000.0 + horizon
encoded_target(value::Float64) = Int(value ÷ 1000) + Int(round(value % 1000))
```

For every row `origin in 1:100`, set `actual_consumption = origin`, `actual_pv = 0`, `load_00:load_95 = encoded(origin, 1:96)`, and all `pv_00:pv_95 = 0`. Use timestamps `DateTime(2026, 1, 1) + Minute(15) * (origin - 1)`.

Assert exactly:

```julia
information = EMSx.Information(1, prices, period, 0.0)
@test information.load[1:3] == [97.0, 96.0, 95.0]
@test information.forecast_load[1] == encoded(97, 1)
@test encoded_target(information.forecast_load[1]) == 98
@test encoded_target(data[2, :load_95]) == 98

stage_cost, _ = EMSx.apply_control(1, 4, prices, period, 0.0, 0.0)
@test stage_cost == 98.0

middle = EMSx.Information(2, prices, period, 0.0)
@test middle.forecast_load[1] == encoded(98, 1)
@test encoded_target(middle.forecast_load[1]) == 99

last = EMSx.Information(4, prices, period, 0.0)
@test last.forecast_load[1] == encoded(100, 1)
last_cost, _ = EMSx.apply_control(4, 4, prices, period, 0.0, 0.0)
@test last_cost == 100.0
@test encoded_target(last.forecast_load[1]) == 101
```

The final two assertions deliberately document EMSx's terminal fallback: forecast target remains conceptual row 101, while `apply_control` repeats row 100 and never indexes out of bounds.

- [ ] **Step 2: Run the standalone offline test to verify it fails**

Run:

```bash
scripts/julia_locked.sh EMSx.jl/test/information.jl
```

Expected: FAIL because current `forecast_load[1]` is encoded from oldest row 2, not latest row 97. No network or dataset access occurs.

- [ ] **Step 3: Make the minimal latest-origin implementation**

Replace only `EMSx.jl/src/struct.jl:114-124` with:

```julia
function Information(t::Int64, prices::Prices, period::Period, soc::Float64)
    data = sort(period.data[t+1:t+96, :], :timestamp; rev=true)
    pv = Vector{Float64}(data[!, :actual_pv])
    load = Vector{Float64}(data[!, :actual_consumption])
    latest = data[1, :]
    forecast_load = Float64[
        latest[Symbol("load_$(lpad(index, 2, '0'))")] for index in 0:95
    ]
    forecast_pv = Float64[
        latest[Symbol("pv_$(lpad(index, 2, '0'))")] for index in 0:95
    ]
    return Information(
        t,
        soc,
        pv,
        forecast_pv,
        load,
        forecast_load,
        prices,
        period.site.battery,
        period.site.id,
    )
end
```

This removes positional column assumptions and sorts explicitly by `:timestamp`; it does not change `simulate_period`, `apply_control`, cost, split, schema, or any forecast consumer.

- [ ] **Step 4: Run nested focused/regression tests**

Run:

```bash
scripts/julia_locked.sh EMSx.jl/test/information.jl
scripts/julia_locked.sh EMSx.jl/test/offline_local_behavior.jl
scripts/julia_locked.sh test/wdwe2_phase_integration.jl
git -C EMSx.jl diff --check
```

Expected: all pass. Re-run `test/legacy_align96.jl` only as a pure helper/renderer test; do not rerun the align96 candidate against changed nested semantics.

- [ ] **Step 5: Nested-only commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git -C EMSx.jl add -- src/struct.jl test/information.jl
git -C EMSx.jl diff --cached --name-only
git -C EMSx.jl commit -m "fix: use latest visible forecast origin"
```

Expected staged set: exactly `src/struct.jl` and `test/information.jl`. Do not stage pre-existing `Project.toml`, `src/simulate.jl`, `examples/sdp/function.jl`, or `test/offline_local_behavior.jl` unless they were already committed through their own Plan 1 confirmations. Never push.

---

### Task 4: Build Training-only Forecast Pairs and Diagnostics

**Files:**
- Create: `src/ForecastPairs.jl`
- Create: `test/forecast_pairs.jl`
- Modify: `test/runtests.jl`

**Interfaces:**
- Consumes: one `dataset/train/<site>.csv.gz`-schema table with timestamps and suffixes `00:95`.
- Produces: `ForecastPairs.build_forecast_pairs(data::DataFrame; horizons::AbstractVector{<:Integer}=collect(1:96))::DataFrame`.
- Produces: `ForecastPairs.load_training_pairs(path::String; horizons=collect(1:96))::DataFrame` with an explicit path guard rejecting any path outside configured train root.
- Produces schema: `site_id::String, origin::DateTime, target::DateTime, horizon::Int, quarter::Int, weekend::Bool, actual_net::Float64, forecast_net::Float64, error::Float64`.
- Produces: `ForecastPairs.forecast_diagnostics(pairs::DataFrame)::DataFrame` with `horizon,n,rmse,bias,coverage_50,coverage_80,coverage_95,mae,p95_abs_error,max_abs_error`.

- [ ] **Step 1: Write failing timestamp-join tests**

Use a synthetic 8-row table at 15-minute intervals with encoded forecasts and remove timestamp 4. Assert:

```julia
pairs = build_forecast_pairs(data; horizons=[1, 3])
@test names(pairs) == [
    "site_id", "origin", "target", "horizon", "quarter", "weekend",
    "actual_net", "forecast_net", "error",
]
@test all(pairs.target .== pairs.origin .+ Minute.(15 .* pairs.horizon))
@test !any(pairs.target .== missing_timestamp)
@test all(pairs.error .== pairs.actual_net .- pairs.forecast_net)
@test all(pairs.horizon .== 1 .|| pairs.horizon .== 3)
```

Also assert duplicate timestamps, unsorted input, mixed site IDs, non-15-minute target arithmetic, missing forecast columns, `NaN`, horizon 0, and horizon 97 fail closed. A train root fixture must accept `train/1.csv.gz` and reject `test/1.csv.gz` before `CSV.read` is called.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
scripts/julia_locked.sh test/forecast_pairs.jl
```

Expected: FAIL because `src/ForecastPairs.jl` does not exist.

- [ ] **Step 3: Implement exact timestamp pairing**

For each origin row and requested `k`, compute `target = origin + Minute(15k)`, look it up in a unique timestamp dictionary, and emit a row only when target actual exists in the same input DataFrame. Map columns with:

```julia
suffix(k::Integer) = lpad(k - 1, 2, '0')
load_column(k::Integer) = Symbol("load_$(suffix(k))")
pv_column(k::Integer) = Symbol("pv_$(suffix(k))")
actual_net = Float64(target_row.actual_consumption - target_row.actual_pv)
forecast_net = Float64(origin_row[load_column(k)] - origin_row[pv_column(k)])
error = actual_net - forecast_net
quarter = Dates.hour(origin) * 4 + Dates.minute(origin) ÷ 15 + 1
weekend = Dates.dayofweek(Date(origin)) in (6, 7)
```

Require sorted unique timestamps and one site; never pair by row offset alone, because official test removal leaves time gaps in train data.

- [ ] **Step 4: Implement deterministic diagnostics**

For each horizon, sort errors once and calculate:

```julia
rmse = sqrt(mean(abs2, error))
bias = mean(error)
mae = mean(abs, error)
p95_abs_error = quantile(abs.(error), 0.95)
max_abs_error = maximum(abs, error)
coverage_50 = mean(quantile(error, 0.25) .<= error .<= quantile(error, 0.75))
coverage_80 = mean(quantile(error, 0.10) .<= error .<= quantile(error, 0.90))
coverage_95 = mean(quantile(error, 0.025) .<= error .<= quantile(error, 0.975))
```

Use explicit elementwise conjunctions in Julia for coverage. Tests must check hand-computed RMSE/bias/MAE and that output horizons are sorted.

- [ ] **Step 5: Run focused and root tests**

Run:

```bash
scripts/julia_locked.sh test/forecast_pairs.jl
scripts/julia_locked.sh test/runtests.jl
git diff --check
```

Expected: all pass; synthetic path spy records zero opens under a `test` directory.

- [ ] **Step 6: Outer commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/ForecastPairs.jl test/forecast_pairs.jl test/runtests.jl
git diff --cached --name-only
git commit -m "feat: build timestamp-aligned forecast pairs"
```

Never push.

---

### Task 5: Fit the Forecast-error Law with Global Shrinkage

**Files:**
- Create: `src/ForecastErrorLaw.jl`
- Create: `test/forecast_error_law.jl`
- Modify: `test/runtests.jl`

**Interfaces:**
- Consumes: Task 4 pairs filtered to `horizon == 1`.
- Produces: `DiscreteErrorLaw(support::Vector{Float64}, probability::Vector{Float64})` with finite sorted support, strictly positive probabilities, and sum 1 within `1e-12`.
- Produces: `ForecastErrorModel(global_law, groups, counts, pseudocount, k)` keyed by `(quarter::Int, weekend::Bool)`.
- Produces: `fit_forecast_error_model(pairs::DataFrame; k::Int=20, pseudocount::Int=32)::ForecastErrorModel`.
- Produces: `error_law(model, origin::DateTime)::DiscreteErrorLaw` and `central_interval(law, coverage::Float64)::Tuple{Float64,Float64}`.

- [ ] **Step 1: Write failing law tests**

Cover:

- weighted quantization of `[0, 0, 10, 10]` into `k=2` gives support `[0, 10]`, probability `[0.5, 0.5]`;
- deterministic output under row permutation;
- exact group key from quarter and weekend;
- dense group receives shrink weight `n / (n + 32)`;
- empty group returns the global law exactly;
- sparse group output differs from both pure local and pure global while remaining finite and normalized;
- only `horizon == 1` is accepted;
- `k < 1`, `pseudocount < 1`, non-finite errors, negative weights, and probability sum drift fail.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
scripts/julia_locked.sh test/forecast_error_law.jl
```

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement deterministic weighted 1-D quantization**

Sort `(value, weight)` by value, merge duplicate values, build prefix sums for weight, weighted value, and weighted square, then use the baseline dynamic-programming partition rule. For interval `a:b`, use:

```julia
weight = prefix_weight[b] - (a > 1 ? prefix_weight[a - 1] : 0.0)
sum_x = prefix_x[b] - (a > 1 ? prefix_x[a - 1] : 0.0)
sum_x2 = prefix_x2[b] - (a > 1 ? prefix_x2[a - 1] : 0.0)
centroid = sum_x / weight
sse = sum_x2 - sum_x^2 / weight
```

On equal total SSE choose the smaller split index, making the result deterministic. Output at most `k` positive-probability support points and normalize once at the end.

- [ ] **Step 4: Implement quarter/weekend global shrink**

For group errors `g` of size `n` and global errors `G` of size `N`, define:

```julia
lambda = n / (n + pseudocount)
values = vcat(g, G)
weights = vcat(fill(lambda / n, n), fill((1 - lambda) / N, N))
```

If `n == 0`, use the global law. Otherwise pass `values, weights, k` to weighted quantization. This is a true finite mixture shrink, not sample duplication and not an AR innovation model. Build all 192 keys `(quarter in 1:96, weekend in (false, true))` so online lookup never invents a fallback.

- [ ] **Step 5: Add out-of-sample coverage diagnostics**

Implement:

```julia
function score_error_model(model::ForecastErrorModel, pairs::DataFrame)::DataFrame
```

Return one row per group with `quarter,weekend,n,rmse,bias,coverage_50,coverage_80,coverage_95,p95_abs_error`; each coverage compares held-out errors against `central_interval(error_law(model, origin), level)`. Tests fit on one synthetic prefix and score a disjoint suffix, proving no fit row appears in score rows.

- [ ] **Step 6: Run tests**

Run:

```bash
scripts/julia_locked.sh test/forecast_error_law.jl
scripts/julia_locked.sh test/forecast_pairs.jl
scripts/julia_locked.sh test/runtests.jl
git diff --check
```

Expected: all pass; every returned law has `1 <= length(support) <= 20` and normalized positive probabilities.

- [ ] **Step 7: Outer commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/ForecastErrorLaw.jl test/forecast_error_law.jl test/runtests.jl
git diff --cached --name-only
git commit -m "feat: fit grouped forecast error laws"
```

Never push.

---

### Task 6: Implement Shared-`z_next` One-step Rollout and a New Runner

**Files:**
- Create: `src/RealtimeRollout.jl`
- Create: `scripts/render_realtime_rollout_runner.jl`
- Create: `sdp_realtime_rollout.jl`
- Create: `configs/realtime_rollout_k20.toml`
- Create: `test/realtime_rollout.jl`
- Modify: `test/runtests.jl`
- Read-only oracle: `sdp_ar1_wdwe2.jl`
- Read-only oracle: `.julia-depot/packages/StoOpt/VMfmk/src/online.jl:6-27`
- Read-only oracle: `.julia-depot/packages/StoOpt/VMfmk/src/offline.jl:6-28`

**Interfaces:**
- Consumes: realtime latest-origin `Information`, Task 5 `ForecastErrorModel`, read-only wdwe2 `StoOpt.ArrayValueFunctions`, and official EMSx battery/cost functions.
- Produces: `RolloutDecision(control::Float64, objective::Float64, clamp_probability::Float64)`.
- Produces: `select_rollout_control(model::StoOpt.SDP, value_functions::StoOpt.ArrayValueFunctions, information::EMSx.Information, law::DiscreteErrorLaw, z_min::Float64, z_max::Float64)::RolloutDecision`.
- Guarantees for each error realization: compute `z_next_raw = b_t + e` once, set `z_next = clamp(z_next_raw,z_min,z_max)` once, and use that exact `z_next` in both `EMSx.compute_stage_cost` and `h[t+1](soc_next,z_next)`.

- [ ] **Step 1: Write a failing Bellman-selector test that detects split semantics**

Use controls `[-1.0, 0.0, 1.0]`, a two-point error law, and a value function whose continuation increases sharply in `z`. Add a trace callback to collect `(control,error,z_stage,z_continuation,slice)` and assert:

```julia
@test all(row.z_stage == row.z_continuation for row in trace)
@test all(row.slice == information.t + 1 for row in trace)
@test decision.control in (-1.0, 0.0, 1.0)
@test decision.objective == minimum(manual_objectives)
@test decision.clamp_probability == manual_clamp_probability
```

Make the manual objective use the same EMSx functions:

```julia
soc_next = EMSx.compute_stage_dynamics(battery, information.soc, control)
z_next = clamp(b_t + error, z_min, z_max)
stage = EMSx.compute_stage_cost(battery, prices, information.t, control, z_next)
continuation = interpolator.value(soc_next, z_next)
objective += probability * (stage + continuation)
```

Add a regression proving the old split formula (`stage: b_t+e`, continuation: `alpha*z+beta+e`) selects a different control on this fixture.

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
scripts/julia_locked.sh test/realtime_rollout.jl
```

Expected: FAIL because `src/RealtimeRollout.jl` does not exist.

- [ ] **Step 3: Implement the pure one-step selector**

Implement explicit control/noise enumeration; do not mutate `model.cost` or `model.dynamics`:

```julia
interpolator = StoOpt.Interpolator(
    information.t + 1,
    model.states,
    value_functions,
)
b_t = ForecastAlignment.realtime_one_step_net(information)
best = RolloutDecision(NaN, Inf, 0.0)
for control_tuple in model.controls[information.t]
    control = Float64(first(control_tuple))
    soc_next = EMSx.compute_stage_dynamics(
        information.battery,
        information.soc,
        control,
    )
    expected = 0.0
    clamp_probability = 0.0
    for (error, probability) in zip(law.support, law.probability)
        z_next_raw = b_t + error
        z_next = clamp(z_next_raw, z_min, z_max)
        clamp_probability += probability * (z_next != z_next_raw)
        stage = EMSx.compute_stage_cost(
            information.battery,
            information.prices,
            information.t,
            control,
            z_next,
        )
        continuation = interpolator.value(soc_next, z_next)
        expected += probability * (stage + continuation)
    end
    if expected < best.objective
        best = RolloutDecision(control, expected, clamp_probability)
    end
end
isfinite(best.objective) || error("no finite realtime rollout control")
return best
```

Before interpolating, require `soc_next` and `z_next` to lie within `model.states.bounds[information.t + 1]`; if a candidate control is out of bounds, assign it `Inf`. Tie-break by the first control in the existing ascending StoOpt control iterator.

- [ ] **Step 4: Create the realtime config**

Create `configs/realtime_rollout_k20.toml` with locked wdwe2 numerical values plus:

```toml
[experiment]
controller = "realtime_forecast_error_rollout_wdwe2"
tag = "realtime_rollout_wdwe2_k20_locked_v1"
seed = 20260731
expected_sites = 70
candidate_spec = "candidates/realtime_rollout_v1/candidate.toml"

[forecast_error]
horizon = 1
k = 20
pseudocount = 32
grouping = "quarter_weekday_weekend"
origin = "latest_visible"

[rollout]
stage_and_continuation_share_z_next = true
clamp = "wdwe2_z_bounds"
continuation_slice_offset = 1
```

Copy `[parameters]`, `[execution]`, `[inputs]` from `configs/wdwe2_k20.toml` byte-for-byte. Tests assert exact equality for those tables and reject any other forecast horizon or `stage_and_continuation_share_z_next = false`.

- [ ] **Step 5: Render a new runner without changing legacy files**

`render_realtime_rollout_runner` must require exact-once replacements and generate `sdp_realtime_rollout.jl` from `sdp_ar1_wdwe2.jl`. Its allowlist is:

1. banner/default config/candidate-spec identity;
2. include `ForecastAlignment`, `ForecastPairs`, `ForecastErrorLaw`, and `RealtimeRollout` inside `PHASE_CODE`;
3. add `forecast_error_model::Union{ForecastErrorModel,Nothing}` to the copied controller and preserve it through the copied constructor;
4. in copied `initialize_site_controller`, build only horizon-1 pairs from `site.path_to_train_data_csv` and fit `k=20,pseudocount=32` after the unchanged wdwe2 model/VF grid construction;
5. replace only the online `compute_control` body with `select_rollout_control(...).control`;
6. add per-site aggregate diagnostics `forecast_rmse,bias,coverage_50,coverage_80,coverage_95,p95_abs_error,clamp_rate` to simulation provenance/artifacts;
7. keep calibration, simulation, evaluation, VF sealing, leases, exact artifact manifests, cleanup and no-overwrite code unchanged.

Generate once:

```bash
scripts/julia_locked.sh scripts/render_realtime_rollout_runner.jl \
  sdp_ar1_wdwe2.jl sdp_realtime_rollout.jl
```

Expected: target created, second generation refuses overwrite. The test regenerates in memory and proves byte equality; it also asserts the rendered runner contains no temporary assignment to `controller.model.cost` or `controller.model.dynamics`.

- [ ] **Step 6: Run one-site development integration**

Use a temporary one-site train/test fixture and copied audited VF. Assert latest-origin encoded `[1]` reaches the selector, diagnostics contain all required columns, source VF hash/mtime remain unchanged, output is strict complete, and rerun refuses the complete path. Run:

```bash
scripts/julia_locked.sh test/realtime_rollout.jl
scripts/julia_locked.sh EMSx.jl/test/information.jl
scripts/julia_locked.sh test/run_contract.jl
scripts/julia_locked.sh test/wdwe2_phase_integration.jl
```

Expected: all pass with no file created under legacy result directories.

- [ ] **Step 7: Run root regression and diff checks**

Run:

```bash
scripts/julia_locked.sh test/runtests.jl
git diff --check
git -C EMSx.jl diff --check
```

Expected: all pass; nested diff contains no new changes after Task 3 commit.

- [ ] **Step 8: Outer commit gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/RealtimeRollout.jl \
  scripts/render_realtime_rollout_runner.jl sdp_realtime_rollout.jl \
  configs/realtime_rollout_k20.toml test/realtime_rollout.jl test/runtests.jl
git diff --cached --name-only
git commit -m "feat: add shared-state realtime forecast rollout"
```

Never push.

---

### Task 7: Select the Candidate with Internal Blocked Validation Only

**Files:**
- Create: `src/BlockedValidation.jl`
- Create: `scripts/run_blocked_validation.jl`
- Create: `configs/realtime_rollout_validation.toml`
- Create: `test/blocked_validation.jl`
- Modify: `test/runtests.jl`
- Runtime only, ignored: `results_sdp/validation/realtime_rollout_v1/<run_id>/**`

**Interfaces:**
- Consumes: training tables only, metadata `max_load`, prices, candidate modules, and fold-local value functions calibrated from each fit prefix.
- Produces: `ValidationFold(site_id::String, fold::Int, fit_end::DateTime, validation_start::DateTime, validation_end::DateTime)`.
- Produces: `build_blocked_folds(data::DataFrame; block_steps::Int=672, folds::Int=3)::Vector{ValidationFold}`.
- Produces: `select_stratified_sites(metadata::DataFrame; per_stratum::Int=3)::Vector{String}`.
- Produces: `select_candidate(metrics::DataFrame)::String` using only validation metrics.
- Produces no-replace `folds.csv`, `forecast-diagnostics.csv`, `policy-metrics.csv`, `selection.toml`, and `artifacts.tsv`.

- [ ] **Step 1: Write failing fold/leakage/selection tests**

Construct train and forbidden test directories under `mktempdir`. Instrument the loader with an `on_open(path)` callback and assert every opened data path is under train. Cover:

- timestamps with a gap split contiguous runs;
- a validation block is exactly 672 consecutive 15-minute timestamps;
- every fit pair has `target < validation_start`;
- every validation origin/target lies within the validation block;
- folds are chronological and non-overlapping;
- fewer than three eligible blocks fails instead of reducing the fold count;
- stratification sorts by `(max_load,site_id)`, divides 70 sites into three contiguous size strata, and chooses rank 25%, 50%, 75% within each stratum;
- duplicate/missing site metadata fails;
- any attempted open under `dataset/test` fails before I/O;
- a second validation output path fails without changing the first artifact manifest.

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
scripts/julia_locked.sh test/blocked_validation.jl
```

Expected: FAIL because `src/BlockedValidation.jl` does not exist.

- [ ] **Step 3: Implement deterministic folds and site strata**

Sort by timestamp, split whenever `timestamp[i] - timestamp[i-1] != Minute(15)`, partition each run into non-overlapping 672-step blocks, then use the last three blocks that each have at least two earlier full blocks available for fitting. For each fold, fit pairs only from rows whose origin and target are strictly before `validation_start`.

For each size stratum with sorted site IDs `ids`, select indices:

```julia
selection_indices(n::Int) = unique(clamp.(round.(Int, [0.25, 0.50, 0.75] .* (n - 1) .+ 1), 1, n))
```

Require exactly three distinct selections per stratum; expected total is nine sites. Save the selected IDs before any policy execution.

- [ ] **Step 4: Lock the candidate matrix and selection rule in config**

Create `configs/realtime_rollout_validation.toml`:

```toml
schema_version = 1
seed = 20260731
block_steps = 672
folds = 3
per_size_stratum = 3
train_root = "dataset/train"
metadata = "dataset/metadata.csv"
prices = "EMSx.jl/metadata/edf_prices.csv"
output_root = "results_sdp/validation/realtime_rollout_v1"

[[candidate]]
name = "realtime_deterministic"
k = 1
pseudocount = 32
error_mode = "zero"

[[candidate]]
name = "realtime_error_k10_p32"
k = 10
pseudocount = 32
error_mode = "quarter_weekday_weekend"

[[candidate]]
name = "realtime_error_k20_p32"
k = 20
pseudocount = 32
error_mode = "quarter_weekday_weekend"

[selection]
primary = "mean_paired_cost_improvement"
tie_tolerance = 1.0e-9
tie_break = ["lower_clamp_rate", "lower_k", "candidate_name"]
```

No residual, weather, forecast-level conditioning, risk parameter, or official test score is in this Plan 2 matrix. Those are separate hypotheses only after this fixed family is falsified on train validation.

- [ ] **Step 5: Implement fold-local calibration and policy scoring**

For every site/fold:

1. materialize a temporary gzip train file containing only rows with timestamps before `validation_start`;
2. calibrate the wdwe2 AR model/value function from that prefix, never from the full official train file;
3. fit the candidate error law from the same prefix pairs;
4. start validation SOC at `0.0` and carry it continuously through the 672-step block;
5. at each origin use latest-origin `[1]`, call the Task 6 selector, apply the official realized next-step net demand to `compute_stage_cost`, then update SOC with `compute_stage_dynamics`;
6. accumulate realized cost, clamp rate, action saturation, SOC boundary occupancy, RMSE/bias/coverage/tail and runtime;
7. delete only the task-owned temporary prefix directory after its hash has been recorded in the fold result.

Compute per-fold paired improvement against `realtime_deterministic`:

```julia
paired_cost_improvement =
    (deterministic_cost - candidate_cost) / max(abs(deterministic_cost), eps(Float64))
```

`select_candidate` maximizes mean paired improvement over exactly 27 site-fold rows. Within `1e-9`, prefer lower mean clamp rate, then lower `k`, then lexical candidate name. It must return exactly one name.

- [ ] **Step 6: Implement immutable validation output**

`run_blocked_validation.jl` requires a non-empty `RUN_ID`, derives `<output_root>/<RUN_ID>`, refuses any existing target, writes all files in a sibling staging directory, creates `artifacts.tsv` with bytes/SHA-256, then atomically hardlinks files into the absent final directory. `selection.toml` contains:

```toml
schema_version = 1
seed = 20260731
site_count = 9
folds_per_site = 3
candidate_count = 3
selected_candidate = "<one exact configured name>"
selection_metric = "mean_paired_cost_improvement"
official_test_files_opened = 0
```

The generated value replacing the angle-bracket description must be one exact configured candidate and is asserted against `policy-metrics.csv`; it is not manually edited.

- [ ] **Step 7: Run synthetic and one-site validation tests**

Run:

```bash
scripts/julia_locked.sh test/blocked_validation.jl
scripts/julia_locked.sh test/forecast_pairs.jl
scripts/julia_locked.sh test/forecast_error_law.jl
scripts/julia_locked.sh test/realtime_rollout.jl
```

Expected: all pass; path-open audit count for official test is zero.

- [ ] **Step 8: Run the pre-specified nine-site train-only validation**

This is not an official 70-site run. Use a unique absent ID:

```bash
RUN_ID=blocked-9site-v1 \
scripts/julia_locked.sh scripts/run_blocked_validation.jl \
  configs/realtime_rollout_validation.toml
```

Expected: strict immutable output with nine sites × three folds × three candidates = 81 policy rows, 27 rows per candidate, no official test opens, exactly one selected candidate, finite metrics, and all artifact hashes valid. A second invocation with the same ID fails without mutation.

- [ ] **Step 9: Run root tests and commit code/config only**

Run:

```bash
scripts/julia_locked.sh test/runtests.jl
git diff --check
```

Expected: all pass.

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/BlockedValidation.jl scripts/run_blocked_validation.jl \
  configs/realtime_rollout_validation.toml test/blocked_validation.jl \
  test/runtests.jl
git diff --cached --name-only
git commit -m "feat: add train-only blocked rollout validation"
```

Do not stage `results_sdp/validation/**`; never push.

---

### Task 8: Pre-lock the Realtime Candidate and 70-site Decision Rule

**Files:**
- Create: `src/CandidateStatistics.jl`
- Create: `test/candidate_statistics.jl`
- Modify: `scripts/lock_forecast_candidate.jl`
- Modify: `test/candidate_lock.jl`
- Modify: `test/runtests.jl`
- Generate once: `candidates/realtime_rollout_v1/candidate.toml`
- Generate once: `candidates/realtime_rollout_v1/validation-artifacts.tsv`
- Generate once: `candidates/realtime_rollout_v1/selection.toml`

**Interfaces:**
- Consumes: Task 7 immutable validation artifact manifest and selected configured name; Plan 1 baseline scores; runner/config/source hashes.
- Produces: `CandidateStatistics.one_sided_lcb(values::Vector{Float64}; seed::Int=20260731, replicates::Int=10_000, alpha::Float64=0.05)::Float64`.
- Produces: `CandidateStatistics.evaluate_endpoints(candidate::DataFrame, baseline::DataFrame; seed=20260731, replicates=10_000)::NamedTuple`.
- Produces: one immutable candidate spec whose hash must enter the future simulation run fingerprint.

- [ ] **Step 1: Write failing statistics tests**

Cover exact sites `1:70`, duplicate/missing/mismatched sites, non-finite score, fewer than 10,000 replicates, invalid alpha, fixed-seed reproducibility, site-cluster mean resampling, and paired resampling with the same index vector. Assert endpoint booleans are exactly:

```julia
mean_passed = mean(candidate.score) > 0.8
absolute_lcb_passed = candidate_lcb > 0.794
paired_lcb_passed = paired_lcb > 0.0
all_passed = mean_passed && absolute_lcb_passed && paired_lcb_passed
```

Use `Statistics.quantile(bootstrap_values, 0.05)` for the one-sided 95% lower bound and `Random.MersenneTwister(seed)`; save the 70 input scores and seed in the returned record.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
scripts/julia_locked.sh test/candidate_statistics.jl
```

Expected: FAIL because `src/CandidateStatistics.jl` does not exist.

- [ ] **Step 3: Implement deterministic candidate statistics**

Sort both DataFrames by integer site ID, require exact `collect(1:70)`, draw a `70`-element index vector with replacement for each replicate, and use that same vector for candidate and baseline in paired differences. Return:

```julia
(
    site_count=70,
    bootstrap_seed=seed,
    bootstrap_replicates=replicates,
    mean_score=mean(candidate.score),
    mean_score_lcb=candidate_lcb,
    mean_paired_improvement=mean(candidate.score .- baseline.score),
    paired_improvement_lcb=paired_lcb,
    mean_passed=mean_passed,
    absolute_lcb_passed=absolute_lcb_passed,
    paired_lcb_passed=paired_lcb_passed,
    all_passed=all_passed,
)
```

Do not round before comparisons.

- [ ] **Step 4: Extend candidate locking for validation evidence**

For `candidate_name = "realtime_rollout_v1"`, require these additional exact fields:

```text
validation_selection_path
validation_selection_sha256
validation_manifest_path
validation_manifest_sha256
selected_candidate
forecast_pair_definition
error_grouping
error_k
error_pseudocount
shared_z_next
bootstrap_seed
bootstrap_replicates
mean_score_threshold
mean_score_lcb_threshold
paired_score_lcb_threshold
expected_output
failure_rule
```

`lock_forecast_candidate.jl` reads Task 7 `selection.toml`, verifies `official_test_files_opened == 0`, verifies all validation artifacts against the runtime manifest, copies only `selection.toml` and its compact artifact manifest into `candidates/realtime_rollout_v1/` using no-replace publication, and writes their hashes into candidate spec. It rejects a selected candidate not present in the fixed config.

- [ ] **Step 5: Generate the final realtime pre-lock**

After all code commits are clean, run:

```bash
scripts/julia_locked.sh scripts/lock_forecast_candidate.jl \
  --name realtime_rollout_v1 \
  --runner sdp_realtime_rollout.jl \
  --config configs/realtime_rollout_k20.toml \
  --tag realtime_rollout_wdwe2_k20_locked_v1 \
  --run-id official-confirmation-v1 \
  --origin latest_visible \
  --horizon 1 \
  --semantics shared_z_next_forecast_error \
  --validation results_sdp/validation/realtime_rollout_v1/blocked-9site-v1 \
  --output candidates/realtime_rollout_v1/candidate.toml
```

Expected: three new compact files appear under `candidates/realtime_rollout_v1/`; selected `k/pseudocount` exactly match Task 7 output; candidate spec records `bootstrap_seed=20260731`, `bootstrap_replicates=10000`, thresholds `0.8`, `0.794`, `0.0`, expected 70 sites, and failure on any incomplete site/provenance/hash/endpoint mismatch. A second invocation fails without mutation.

- [ ] **Step 6: Verify the pre-lock milestone without running official 70 sites**

Run:

```bash
scripts/julia_locked.sh test/candidate_statistics.jl
scripts/julia_locked.sh test/candidate_lock.jl
scripts/julia_locked.sh test/runtests.jl
scripts/julia_locked.sh EMSx.jl/test/information.jl
scripts/julia_locked.sh -e '
include("src/CandidateLock.jl")
using .CandidateLock
spec = assert_candidate_spec!(
    "candidates/realtime_rollout_v1/candidate.toml";
    root=pwd(),
    expected_name="realtime_rollout_v1",
)
@assert spec["expected_sites"] == 70
@assert spec["bootstrap_seed"] == 20260731
@assert spec["bootstrap_replicates"] == 10_000
@assert spec["shared_z_next"] == true
@assert spec["mean_score_threshold"] == 0.8
@assert spec["mean_score_lcb_threshold"] == 0.794
@assert spec["paired_score_lcb_threshold"] == 0.0
'
git diff --check
git -C EMSx.jl diff --check
```

Expected: all pass; no path under `results_sdp/runs/realtime_rollout_wdwe2_k20_locked_v1/official-confirmation-v1` exists.

- [ ] **Step 7: Commit the pre-lock in its own confirmation gate**

Stop and obtain separate confirmation. Only after confirmation:

```bash
git add -- src/CandidateStatistics.jl test/candidate_statistics.jl \
  src/CandidateLock.jl scripts/lock_forecast_candidate.jl \
  test/candidate_lock.jl test/runtests.jl \
  candidates/realtime_rollout_v1/candidate.toml \
  candidates/realtime_rollout_v1/selection.toml \
  candidates/realtime_rollout_v1/validation-artifacts.tsv
git diff --cached --name-only
git commit -m "test: prelock realtime rollout candidate"
```

Never push.

- [ ] **Step 8: STOP at the 70-site authorization boundary**

Do not execute these commands as part of pre-lock. Record them verbatim for the separately authorized confirmation milestone:

```bash
EXPERIMENT_CONFIG="$PWD/configs/realtime_rollout_k20.toml" \
CANDIDATE_SPEC="$PWD/candidates/realtime_rollout_v1/candidate.toml" \
PHASE=simulate \
RUN_ID=official-confirmation-v1 \
VALUE_FUNCTION_SOURCE_DIR="$PWD/results_sdp/sweep_wdwe2_k20/value_functions" \
VALUE_FUNCTION_MANIFEST="$PWD/baselines/wdwe2_k20/vf-manifest.tsv" \
scripts/julia_locked.sh sdp_realtime_rollout.jl

EXPERIMENT_CONFIG="$PWD/configs/realtime_rollout_k20.toml" \
CANDIDATE_SPEC="$PWD/candidates/realtime_rollout_v1/candidate.toml" \
PHASE=evaluate \
RUN_ID=official-confirmation-v1 \
SIMULATION_SOURCE_DIR="$PWD/results_sdp/runs/realtime_rollout_wdwe2_k20_locked_v1/official-confirmation-v1/simulate" \
scripts/julia_locked.sh sdp_realtime_rollout.jl
```

Before a later session runs them, it must obtain explicit user authorization, verify both repositories clean, revalidate the candidate spec, require the output paths absent, and snapshot legacy hashes. Afterward it must call `CandidateStatistics.evaluate_endpoints` against `baselines/wdwe2_k20/reproduced-scores.csv`; failure of any of the three hard endpoints is a valid negative result and must not trigger test-score-only parameter search.

---

## Plan 2 Completion Contract

This plan is complete at the pre-lock milestone only when:

- Plan 1 Task 6 reuse and recalibrated paths both have immutable compact evidence and exact `1e-6` mean/site regression passes;
- align96 was rendered from the read-only baseline runner, pre-locked under legacy nested SHA, and its single-variable renderer audit passes;
- encoded timestamp tests prove latest-to-oldest history, legacy `[96]` target equivalence, realtime latest-origin `[1]`, actual billing row, middle step, and final-step fallback;
- the only nested behavior change is `EMSx.jl/src/struct.jl:114-124`, committed separately after explicit confirmation;
- forecast pairs are joined by timestamp entirely within train data and diagnostics report RMSE, bias, 50/80/95 coverage, MAE, p95 and max tail error;
- forecast error is a deterministic finite quarter/weekend law with explicit global shrink, not an AR innovation alias;
- the rollout unit test proves the identical clamped `z_next` enters stage cost and `h[t+1]` for every error realization;
- synthetic, one-site and nine-site/three-fold blocked validation pass with zero official test opens and exactly one selected candidate;
- candidate statistics use at least 10,000 fixed-seed site-cluster resamples and paired indices;
- final candidate spec, validation selection and artifact manifest are immutable, hashed, committed through a separate confirmation, and included in the future run fingerprint;
- no legacy/data/official scoring artifact changed, no result was overwritten, no global package was edited, no `results_sdp/**` file was staged, and no push occurred;
- official realtime 70-site output path is still absent at completion of this plan; execution stops for separate authorization.
