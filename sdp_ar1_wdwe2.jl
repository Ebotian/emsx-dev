#!/usr/bin/env julia
# ============================================================================
# EMSx SDP-AR(1) — locked calibration, simulation, and evaluation phases
# ============================================================================
# Run with PHASE and RUN_ID through scripts/julia_locked.sh. Output locations
# are derived exclusively from the locked experiment configuration. Task 6 callers may
# pass RUN_OUTPUT_DIR only when it is empty or exactly matches that derived location.
# ============================================================================

using CSV
using DataFrames
using Distributed
using EMSx
using JLD2
using LinearAlgebra
using ProgressMeter
using Statistics
using TOML

const ROOT = normpath(abspath(@__DIR__))
include(joinpath(ROOT, "src", "EnvironmentIdentity.jl"))
include(joinpath(ROOT, "src", "Provenance.jl"))
include(joinpath(ROOT, "src", "RunContract.jl"))
using .EnvironmentIdentity
using .Provenance
using .RunContract

EnvironmentIdentity.assert_environment!(ROOT)

_is_contained(path::String, root::String) = begin
    relative = relpath(path, root)
    !isabspath(relative) && relative != ".." &&
        !startswith(relative, "..$(Base.Filesystem.path_separator)")
end

function canonical_config_path(value, label::String; existing::Bool, directory::Bool=false)
    value isa String && !isempty(value) || error("$(label) must be a non-empty string")
    any(iscntrl, value) && error("$(label) contains a control character")
    occursin('\\', value) && error("$(label) uses a non-canonical separator")
    normpath(value) == value || error("$(label) spelling is not canonical: $(value)")
    if !isabspath(value)
        parts = split(value, '/'; keepempty=true)
        all(part -> !isempty(part) && part != "." && part != "..", parts) ||
            error("$(label) spelling is not canonical: $(value)")
    end

    lexical = isabspath(value) ? value : joinpath(ROOT, split(value, '/')...)
    lexical = normpath(abspath(lexical))
    _is_contained(lexical, ROOT) || error("$(label) escapes ROOT: $(value)")

    current = lexical
    while !ispath(current) && !islink(current)
        parent = dirname(current)
        parent == current && error("$(label) has no existing canonical ancestor")
        current = parent
    end
    while true
        if islink(current)
            current == lexical && error("$(label) must not be a symlink: $(current)")
            error("$(label) contains a symlink component: $(current)")
        end
        current == ROOT && break
        _is_contained(current, ROOT) || error("$(label) escapes ROOT physically")
        parent = dirname(current)
        parent == current && error("$(label) escapes ROOT physically")
        current = parent
    end

    if existing
        ispath(lexical) || error("missing $(label): $(lexical)")
        islink(lexical) && error("$(label) must not be a symlink: $(lexical)")
        realpath(lexical) == lexical || error("$(label) is a physical alias: $(lexical)")
        directory ? isdir(lexical) : isfile(lexical) ||
            error("$(label) has the wrong file type: $(lexical)")
        directory && !isdir(lexical) &&
            error("$(label) has the wrong file type: $(lexical)")
    end
    return lexical
end

function paths_overlap(left::String, right::String)
    left == right && return true
    return _is_contained(left, right) || _is_contained(right, left)
end

const CONFIG_PATH = canonical_config_path(
    get(ENV, "EXPERIMENT_CONFIG", joinpath(ROOT, "configs", "wdwe2_k20.toml")),
    "experiment config";
    existing=true,
)
const CONFIG = TOML.parsefile(CONFIG_PATH)
const PARAMETERS = CONFIG["parameters"]
const EXECUTION = CONFIG["execution"]
const INPUTS = CONFIG["inputs"]
Set(keys(INPUTS)) == Set(("input_manifest", "prices", "metadata", "train", "test")) ||
    error("inputs must contain exactly input_manifest, prices, metadata, train, and test")

const DX = Float64(PARAMETERS["dx"])
const DU = Float64(PARAMETERS["du"])
const K_NOISE = Int(PARAMETERS["k_noise"])
const MARGIN = Float64(PARAMETERS["margin"])
const NZ = Int(PARAMETERS["nz"])
const HORIZON = Int(PARAMETERS["horizon"])
const MAX_VI_ITERS_CONFIG = Int(PARAMETERS["max_vi_iters"])
const VI_TOL_CONFIG = Float64(PARAMETERS["vi_tol"])
const TAG = String(CONFIG["experiment"]["tag"])
const EXPECTED_SITES = Int(CONFIG["experiment"]["expected_sites"])
const N_WORKERS = Int(EXECUTION["workers"])
const FORMAL_SETTING = get(EXECUTION, "formal", true)
FORMAL_SETTING isa Bool || error("execution.formal must be a Bool")
const FORMAL = FORMAL_SETTING

const PHASE = Symbol(get(ENV, "PHASE", ""))
const RUN_ID = get(ENV, "RUN_ID", "")
const LEGACY_OUTPUT_OVERRIDE = get(ENV, "RUN_OUTPUT_DIR", "")
const VALUE_FUNCTION_SOURCE_SETTING = get(ENV, "VALUE_FUNCTION_SOURCE_DIR", "")
const VALUE_FUNCTION_MANIFEST_SETTING = get(ENV, "VALUE_FUNCTION_MANIFEST", "")
const SIMULATION_SOURCE_SETTING = get(ENV, "SIMULATION_SOURCE_DIR", "")

PHASE in (:calibrate, :simulate, :evaluate) ||
    error("PHASE must be calibrate, simulate, or evaluate")
RunContract.validate_component(TAG, "TAG")
RunContract.validate_component(RUN_ID, "RUN_ID")

# The formal dirty gate and its immutable start identity are deliberately ahead of
# output, lock, and worker creation.
FORMAL && Provenance.assert_formal_sources_clean!(ROOT)
const FORMAL_OUTER_START = FORMAL ? Provenance.git_state(ROOT) : nothing
const FORMAL_NESTED_START =
    FORMAL ? Provenance.git_state(joinpath(ROOT, "EMSx.jl")) : nothing
FORMAL && haskey(CONFIG, "development") &&
    error("formal configurations must not contain development settings")
!FORMAL && !haskey(CONFIG, "development") &&
    error("development.output_root is required when formal=false")

const DEVELOPMENT = FORMAL ? Dict{String,Any}() : Dict{String,Any}(
    String(key) => value for (key, value) in CONFIG["development"]
)
const DEVELOPMENT_KEYS = Set((
    "output_root",
    "fail_before_work_file",
    "fail_before_provenance_file",
    "fail_before_score_file",
    "pause_after_cleanup_file",
))
issubset(Set(keys(DEVELOPMENT)), DEVELOPMENT_KEYS) ||
    error("development settings contain an unsupported key")

const INPUT_MANIFEST = canonical_config_path(
    INPUTS["input_manifest"],
    "input manifest";
    existing=true,
)
const PRICE_PATH = canonical_config_path(INPUTS["prices"], "prices"; existing=true)
const METADATA_PATH =
    canonical_config_path(INPUTS["metadata"], "metadata"; existing=true)
const TRAIN_PATH =
    canonical_config_path(INPUTS["train"], "train"; existing=true, directory=true)
const TEST_PATH =
    canonical_config_path(INPUTS["test"], "test"; existing=true, directory=true)
const EMSX_DIR = canonical_config_path("EMSx.jl", "EMSx checkout"; existing=true, directory=true)
const OUTPUT_ROOT = FORMAL ?
                    canonical_config_path(
    "results_sdp/runs",
    "formal output root";
    existing=false,
    directory=true,
) : canonical_config_path(
    DEVELOPMENT["output_root"],
    "development output root";
    existing=false,
    directory=true,
)
const RUN_OUTPUT_DIR = normpath(joinpath(OUTPUT_ROOT, TAG, RUN_ID, String(PHASE)))
const STAGING_NAMESPACE =
    joinpath(dirname(RUN_OUTPUT_DIR), ".emsx-task5-staging-$(basename(RUN_OUTPUT_DIR))")
if !isempty(LEGACY_OUTPUT_OVERRIDE)
    normpath(abspath(LEGACY_OUTPUT_OVERRIDE)) == RUN_OUTPUT_DIR ||
        error("RUN_OUTPUT_DIR must equal the derived phase output")
end
const CONFIG_GUARD = Provenance.capture_stable_file_guard(CONFIG_PATH, ROOT)
const INPUT_SNAPSHOT = Provenance.capture_manifest_snapshot(INPUT_MANIFEST, ROOT)

function development_hook_path(key::String)
    FORMAL && return nothing
    haskey(DEVELOPMENT, key) || return nothing
    return canonical_config_path(
        DEVELOPMENT[key],
        "development.$(key)";
        existing=false,
    )
end

function development_fail_if_present!(key::String, message::String)
    path = development_hook_path(key)
    path === nothing || !isfile(path) || error(message)
    return nothing
end

function development_pause_after_cleanup!()
    path = development_hook_path("pause_after_cleanup_file")
    path === nothing && return nothing
    while !isfile(path)
        sleep(0.05)
    end
    return nothing
end

function input_manifest_files()
    files = String[
        PRICE_PATH,
        METADATA_PATH,
        joinpath(EMSX_DIR, "metadata", "baseline", "anticipative.jld2"),
        joinpath(EMSX_DIR, "metadata", "baseline", "dummy.jld2"),
    ]
    for directory in (TRAIN_PATH, TEST_PATH)
        for name in sort(readdir(directory))
            path = joinpath(directory, name)
            islink(path) && error("input directory contains a symlink: $(path)")
            isfile(path) || error("input directory contains a non-file: $(path)")
            realpath(path) == path || error("input file is a physical alias: $(path)")
            push!(files, path)
        end
    end
    return files
end

const MANIFESTED_INPUTS = input_manifest_files()
const MANIFESTED_INPUT_PATHS = Set(
    normpath(joinpath(ROOT, split(entry.path, '/')...)) for entry in INPUT_SNAPSHOT.entries
)
Set(MANIFESTED_INPUTS) == MANIFESTED_INPUT_PATHS ||
    error("input manifest does not exactly cover configured scientific inputs")
length(unique(realpath.(MANIFESTED_INPUTS))) == length(MANIFESTED_INPUTS) ||
    error("configured scientific inputs contain a physical alias")

function input_entries(paths::Vector{String})
    relative = [replace(relpath(path, ROOT), '\\' => '/') for path in paths]
    return Provenance.select_manifest_entries(INPUT_SNAPSHOT, relative)
end

const GLOBAL_INPUT_ENTRIES = input_entries([PRICE_PATH, METADATA_PATH])

@info "Config: phase=$PHASE DX=$DX DU=$DU K=$K_NOISE MARGIN=$MARGIN NZ=$NZ TAG=$TAG"

# ── Load modules and phase code only while checked workers are alive ───────────
const PHASE_CODE = quote
    isdefined(Main, :Provenance) || include(joinpath($ROOT, "src", "Provenance.jl"))
    using EMSx
    using StoOpt
    using ControlVariables
    using JLD2
    using CSV, DataFrames, Dates
    using ProgressMeter
    using Statistics
    using LinearAlgebra
    using Interpolations: linear_interpolation, Line

    include(joinpath($EMSX_DIR, "examples", "sdp", "function.jl"))
    include(joinpath($EMSX_DIR, "examples", "sdp", "calibrate.jl"))

    # ── Constants ──────────────────────────────────────────────────────────────
    const dx = $DX        # SoC discretization
    const du = $DU        # control discretization
    const horizon = $HORIZON  # 7 days × 96 steps/day
    const NZ = $NZ        # z grid points (net demand dimension)
    const K_NOISE = $K_NOISE   # number of noise levels
    const MARGIN_FRAC = $MARGIN
    const MAX_VI_ITERS = $MAX_VI_ITERS_CONFIG
    const VI_TOL = $VI_TOL_CONFIG

    function write_jld2_payload!(path::String, payload::AbstractDict)
        JLD2.jldopen(path, "w") do file
            for (key, value) in payload
                file[string(key)] = value
            end
        end
        return nothing
    end

    # ══════════════════════════════════════════════════════════════════════════
    # A₁: Deterministic 1D DP Optimal Quantization (inherited)
    # ══════════════════════════════════════════════════════════════════════════

    function interval_sse(prefix_sum::Vector{Float64}, prefix_sqsum::Vector{Float64},
                          a::Int64, b::Int64)
        n = b - a + 1
        s = prefix_sum[b] - (a > 1 ? prefix_sum[a-1] : 0.0)
        sq = prefix_sqsum[b] - (a > 1 ? prefix_sqsum[a-1] : 0.0)
        return sq - s * s / n
    end

    function deterministic_quantize_1d(epsilon::Vector{Float64}, K::Int64)
        n = length(epsilon)
        K = min(K, n)
        sorted_eps = sort(epsilon)
        prefix_sum = zeros(Float64, n)
        prefix_sqsum = zeros(Float64, n)
        prefix_sum[1] = sorted_eps[1]
        prefix_sqsum[1] = sorted_eps[1]^2
        for i in 2:n
            prefix_sum[i] = prefix_sum[i-1] + sorted_eps[i]
            prefix_sqsum[i] = prefix_sqsum[i-1] + sorted_eps[i]^2
        end
        INF = Float64(1e18)
        D = fill(INF, K, n)
        back = zeros(Int64, K, n)
        for j in 1:n
            D[1, j] = interval_sse(prefix_sum, prefix_sqsum, 1, j)
        end
        for k in 2:K
            for j in k:n
                best_cost = INF
                best_m = k - 1
                for m in (k-1):(j-1)
                    cost = D[k-1, m] + interval_sse(prefix_sum, prefix_sqsum, m+1, j)
                    if cost < best_cost
                        best_cost = cost
                        best_m = m
                    end
                end
                D[k, j] = best_cost
                back[k, j] = best_m
            end
        end
        levels = Vector{Vector{Int64}}()
        j = n
        for k in K:-1:1
            m = back[k, j]
            push!(levels, collect((m+1):j))
            j = m
        end
        reverse!(levels)
        support = Float64[]
        probability = Float64[]
        for indices in levels
            if isempty(indices)
                continue
            end
            a = indices[1]
            b = indices[end]
            s = prefix_sum[b] - (a > 1 ? prefix_sum[a-1] : 0.0)
            cnt = b - a + 1
            push!(support, s / cnt)
            push!(probability, cnt / n)
        end
        return support, probability
    end

    """
    AR(1) noise model with weekday/weekend separation (matching paper §5.2.2).
    Fits 2×96=192 AR(1) regressions (weekday + weekend, 96 time slots each),
    then fills 672 steps (5 weekday + 2 weekend).
    Uses deterministic 1D DP quantization for residuals.
    Returns (weights, Noises, weeks_data).
    """
    function fit_linear_noise_model_wdwe(path_to_data_csv::String, k::Int64=K_NOISE)
        data = EMSx.read_site_file(path_to_data_csv)
        net_demand = Float64.(data[!, :actual_consumption] .- data[!, :actual_pv])
        n = length(net_demand)
        n_weeks = n ÷ horizon
        if n_weeks < 2
            error("Not enough data: $n steps ($n_weeks weeks)")
        end
        net_demand = net_demand[1:n_weeks * horizon]
        weeks_data = collect(reshape(net_demand, horizon, n_weeks)')

        # Day-of-week: t=1..96=day1(Mon), t=97..192=day2(Tue), ... t=577..672=day7(Sun)
        is_weekend = falses(horizon)
        for t in 1:horizon
            day_of_week = ((t - 1) ÷ 96) + 1
            is_weekend[t] = day_of_week >= 6
        end

        weights = zeros(2, horizon)
        support = zeros(k, horizon)
        probability = zeros(k, horizon)

        # Precompute group data: for each (quarter, is_weekend) pair,
        # collect all (z_prev, z_t) pairs across all weeks and all matching slots
        group_cache = Dict{Tuple{Int64,Bool},Tuple{Vector{Float64},Vector{Float64}}}()
        for t in 1:horizon
            q = ((t - 1) % 96) + 1
            we = is_weekend[t]
            key = (q, we)
            if !haskey(group_cache, key)
                xs_g = Float64[]
                ys_g = Float64[]
                for w in 1:n_weeks
                    for tt in 1:horizon
                        if ((tt - 1) % 96) + 1 == q && is_weekend[tt] == we
                            if tt == 1
                                push!(xs_g, weeks_data[w, horizon])
                                push!(ys_g, weeks_data[w, 1])
                            else
                                push!(xs_g, weeks_data[w, tt-1])
                                push!(ys_g, weeks_data[w, tt])
                            end
                        end
                    end
                end
                group_cache[key] = (xs_g, ys_g)
            end
        end

        for t in 1:horizon
            q = ((t - 1) % 96) + 1
            we = is_weekend[t]
            xs_g, ys_g = group_cache[(q, we)]

            # OLS regression on the group
            X = hcat(xs_g, ones(length(xs_g)))
            w_reg = pinv(X'X) * X'ys_g
            weights[1, t] = w_reg[1]
            weights[2, t] = w_reg[2]

            # Compute residuals for the entire group (shared quantization)
            X_all = hcat(xs_g, ones(length(xs_g)))
            epsilon_all = ys_g - X_all * w_reg

            # Deterministic quantization of ALL group residuals (shared)
            supp, prob = deterministic_quantize_1d(epsilon_all, k)
            for i in 1:k
                if i <= length(supp)
                    support[i, t] = supp[i]
                    probability[i, t] = prob[i]
                else
                    support[i, t] = supp[end]
                    probability[i, t] = 0.0
                end
            end
        end

        return weights, Noises(support, probability), weeks_data
    end

    # ══════════════════════════════════════════════════════════════════════════
    # A₂: Periodic Average-Cost Value Iteration
    # ══════════════════════════════════════════════════════════════════════════
    # Given an SDP model, run multiple rounds of backward DP, each time using
    # the previous round's V[1] as the new terminal value V[horizon+1].
    # This enforces the periodic boundary condition V[1] = V[horizon+1],
    # which is the Bellman equation for the average-cost (infinite-horizon) MDP.
    # ───────────────────────────────────────────────────────────────────────────

    """
    Build a final_cost function from a value function at step 1.
    The returned function takes a state vector [soc, z] and returns
    the interpolated value from the provided value function array.
    Uses Line() extrapolation (linear extension beyond grid) to handle
    states slightly outside the grid bounds.
    """
    function make_periodic_final_cost(sdp_model::StoOpt.SDP, vf_step1::Array{Float64})
        soc_axis = sdp_model.states.axis[1]
        z_axis   = sdp_model.states.axis[2]
        # linear_interpolation with Line() extrapolation for boundary robustness
        itp = linear_interpolation((soc_axis, z_axis), vf_step1; extrapolation_bc=Line())
        return (state::Array{Float64,1}) -> itp(state[1], state[2])
    end

    """
    Compute value functions with periodic boundary condition (A₂).
    Runs multiple rounds of backward DP until V[1] converges.
    Returns the final value functions and the number of iterations.
    """
    function compute_periodic_value_functions(sdp_model::StoOpt.SDP;
                                                max_iters::Int64=MAX_VI_ITERS,
                                                tol::Float64=VI_TOL)
        # Round 1: standard backward DP with V_{horizon+1}=0
        vf = StoOpt.compute_value_functions(sdp_model)
        prev_v1 = copy(vf[1])

        for iter in 1:max_iters
            # Set final_cost to interpolated V[1] from previous round
            final_cost_fn = make_periodic_final_cost(sdp_model, vf[1])
            sdp_model.final_cost = final_cost_fn

            # Re-run backward DP with new terminal value
            vf = StoOpt.compute_value_functions(sdp_model)

            # Average-cost VI: V grows by a constant g* each iteration.
            # Convergence is on the SHAPE (de-meaned), not absolute values.
            cur_v1 = vf[1]
            cur_mean = mean(cur_v1)
            prev_mean = mean(prev_v1)
            cur_centered = cur_v1 .- cur_mean
            prev_centered = prev_v1 .- prev_mean
            shape_diff = maximum(abs.(cur_centered .- prev_centered))
            g_estimate = cur_mean - prev_mean
            @info "    VI iter $iter: shape_diff=$(round(shape_diff, digits=4)), g*=$(round(g_estimate, digits=2))"

            if shape_diff < tol
                @info "    VI shape converged at iter $iter"
                break
            end
            prev_v1 = copy(vf[1])
        end

        # Reset final_cost to nothing (clean state)
        sdp_model.final_cost = nothing

        return vf
    end

    # ══════════════════════════════════════════════════════════════════════════
    # SDP-AR(1) Controller (A₂ variant)
    # ══════════════════════════════════════════════════════════════════════════
    mutable struct SdpAr1A2 <: EMSx.AbstractController
        model::Union{StoOpt.SDP, Nothing}
        value_functions::Union{StoOpt.ArrayValueFunctions, Nothing}
        alpha::Union{Array{Float64,1}, Nothing}
        beta::Union{Array{Float64,1}, Nothing}
        z_min::Float64
        z_max::Float64
        value_function_source_dir::String
        value_function_snapshot::Any
        value_function_entries::Any
        value_function_guards::Any
        SdpAr1A2(
            value_function_source_dir::String="",
            value_function_snapshot=nothing,
            value_function_entries=nothing,
            value_function_guards=nothing,
        ) = new(
            nothing,
            nothing,
            nothing,
            nothing,
            0.0,
            0.0,
            value_function_source_dir,
            value_function_snapshot,
            value_function_entries,
            value_function_guards,
        )
    end

    # ── Data preparation for AR(1) ────────────────────────────────────────────
    # ── Data preparation: now handled inside fit_linear_noise_model_wdwe ──────
    # (kept for reference, not used in wdwe variant)
    function net_demand_ar1_data(path_to_data_csv::String)
        data = EMSx.read_site_file(path_to_data_csv)
        net_demand = Float64.(data[!, :actual_consumption] .- data[!, :actual_pv])
        n = length(net_demand)
        n_weeks = n ÷ horizon
        if n_weeks < 2
            error("Not enough data")
        end
        net_demand = net_demand[1:n_weeks * horizon]
        return collect(reshape(net_demand, horizon, n_weeks)')
    end

    # ── Per-site controller initialization ─────────────────────────────────────
    function EMSx.initialize_site_controller(
        controller::SdpAr1A2,
        site::EMSx.Site,
        prices::EMSx.Prices,
    )
        controller = SdpAr1A2(
            controller.value_function_source_dir,
            controller.value_function_snapshot,
            controller.value_function_entries,
            controller.value_function_guards,
        )

        # 1) Fit AR(1) with weekday/weekend grouping + deterministic quantization
        weights, noises, weeks_data = fit_linear_noise_model_wdwe(site.path_to_train_data_csv, K_NOISE)

        alpha = weights[1, :]
        beta  = weights[2, :]

        # 2) Compute z grid range
        z_values = vec(weeks_data)
        z_lo, z_hi = extrema(z_values)
        z_range = z_hi - z_lo
        margin = MARGIN_FRAC * max(z_range, 1e-3)
        z_min = z_lo - margin
        z_max = z_hi + margin

        controller.alpha = alpha
        controller.beta  = beta
        controller.z_min = z_min
        controller.z_max = z_max

        # 3) Build z grid axis
        z_axis = range(z_min, z_max, length=NZ)

        # 4) Capture site battery params for closures
        _charge_eff   = site.battery.charge_efficiency
        _discharge_eff = site.battery.discharge_efficiency
        _power        = site.battery.power
        _capacity     = site.battery.capacity
        _scale_factor = _power * 0.25 / _capacity
        _buy_prices   = prices.buy
        _sell_prices  = prices.sell

        # 5) Dynamics
        function offline_dynamics(t::Int64, state::Array{Float64,1},
                                  control::Array{Float64,1}, noise::Array{Float64,1})
            soc = state[1] + (_charge_eff * max(0., control[1]) -
                              max(0., -control[1]) / _discharge_eff) * _scale_factor
            z   = alpha[t] * state[2] + beta[t] + noise[1]
            z   = clamp(z, z_min, z_max)
            return [soc, z]
        end

        # 6) Cost
        function offline_cost(t::Int64, state::Array{Float64,1},
                              control::Array{Float64,1}, noise::Array{Float64,1})
            z_pred = alpha[t] * state[2] + beta[t] + noise[1]
            control_kwh = control[1] * _power * 0.25
            imported_energy = control_kwh + z_pred
            return (_buy_prices[t] * max(0., imported_energy) -
                    _sell_prices[t] * max(0., -imported_energy))
        end

        # 7) Build 2D SDP model
        model = StoOpt.SDP(
            States(horizon, 0.0:dx:1.0, z_axis),
            Controls(horizon, -1.0:du:1.0),
            noises,
            offline_cost,
            offline_dynamics,
            horizon
        )
        controller.model = model
        return controller
    end

    # ── A₂: Value function computation with periodic VI ────────────────────────
    function compute_value_functions(controller::SdpAr1A2)
        return compute_periodic_value_functions(controller.model)
    end

    # ── Load value functions from the sealed read-only source ──────────────────
    function verify_value_function_source!(snapshot, entries, guards)
        snapshot === nothing && error("value-function manifest snapshot is required")
        entries === nothing && error("value-function manifest entries are required")
        guards === nothing && error("value-function source guards are required")
        for guard in guards
            Provenance.verify_stable_file_guard(guard)
        end
        Provenance.verify_stable_file_guard(snapshot.manifest_guard)
        Provenance.verify_manifest_entries(snapshot, entries)
        return nothing
    end

    function load_value_functions(
        site_id::String,
        source_dir::String,
        snapshot,
        entries,
        guards,
    )
        isempty(source_dir) && error("VALUE_FUNCTION_SOURCE_DIR is required")
        path = joinpath(source_dir, site_id * ".jld2")
        isfile(path) || error("missing value function: $(path)")
        verify_value_function_source!(snapshot, entries, guards)
        payload = JLD2.load(path)
        haskey(payload, "value_function") ||
            error("value-function payload is incomplete for site $(site_id)")
        verify_value_function_source!(snapshot, entries, guards)
        return payload["value_function"]
    end

    # ── Online: compute control at each time step ──────────────────────────────
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
        control = StoOpt.compute_control(
            controller.model,
            information.t,
            [information.soc, z_t],
            StoOpt.RandomVariable(controller.model.noises, information.t),
            controller.value_functions,
        )
        return control[1]
    end

    # ══════════════════════════════════════════════════════════════════════════
    # A₂: Continuous-SOC simulation (soc carries across periods)
    # ══════════════════════════════════════════════════════════════════════════
    # The stock EMSx simulator resets soc=0 at each period boundary.
    # For A₂ (periodic average-cost SDP), the value function assumes
    # continuous operation. This custom simulator passes soc from the
    # end of one period to the start of the next, matching the SDP's
    # periodic boundary condition.
    # ───────────────────────────────────────────────────────────────────────────

    function simulate_site_continuous(controller::EMSx.AbstractController,
                                        site::EMSx.Site, prices::EMSx.Prices)
        test_data, site = EMSx.load_site_data(site)
        controller = EMSx.initialize_site_controller(controller, site, prices)
        periods = unique(test_data[!, :period_id])
        simulations = EMSx.Simulation[]
        expected_horizons = Dict{String,Int}()

        # Continuous SOC: carries across periods (was 0.0 each period in stock)
        state_of_charge = 0.0

        for period_id in periods
            test_data_period = test_data[test_data.period_id .== period_id, :]
            period = EMSx.Period(string(period_id), test_data_period, site)
            h = size(period.data, 1) - 96
            h > 0 || error("non-positive simulation horizon for period $(period.id)")
            expected_horizons[period.id] = h
            id = EMSx.Id(period.site.id, period.id, prices.name, string(typeof(controller)))
            result = EMSx.Result(h)
            timer = zeros(h)

            for t in 1:h
                information = EMSx.Information(t, prices, period, state_of_charge)
                timing = @elapsed control = EMSx.compute_control(controller, information)

                stage_cost, state_of_charge = EMSx.apply_control(t, h, prices, period,
                                                                  state_of_charge, control)
                result.cost[t] = stage_cost
                result.control[t] = control
                result.soc[t] = state_of_charge
                timer[t] = timing
            end

            push!(simulations, EMSx.Simulation(result, timer, id))
        end

        return (simulations=simulations, expected_horizons=expected_horizons)
    end

    function calibrate_site_atomic!(site, prices, output, input_snapshot, input_entries)
        Provenance.verify_stable_file_guard(input_snapshot.manifest_guard)
        Provenance.verify_manifest_entries(input_snapshot, input_entries)
        ctrl = EMSx.initialize_site_controller(SdpAr1A2(), site, prices)
        timer = @elapsed value_function = compute_value_functions(ctrl)
        mkpath($STAGING_NAMESPACE)
        temporary, io = mktemp($STAGING_NAMESPACE)
        close(io)
        try
            write_jld2_payload!(
                temporary,
                Dict(
                    "value_function" => value_function,
                    "time" => timer,
                    "alpha" => ctrl.alpha,
                    "beta" => ctrl.beta,
                    "z_min" => ctrl.z_min,
                    "z_max" => ctrl.z_max,
                ),
            )
            payload = JLD2.load(temporary)
            required = ("value_function", "time", "alpha", "beta", "z_min", "z_max")
            all(key -> haskey(payload, key), required) ||
                error("incomplete value-function output for site $(site.id)")
            size(payload["value_function"]) ==
                (horizon + 1, length(0.0:dx:1.0), NZ) ||
                error("invalid value-function shape for site $(site.id)")
            length(payload["alpha"]) == horizon || error("invalid alpha length")
            length(payload["beta"]) == horizon || error("invalid beta length")
            all(time -> all(isfinite, payload["value_function"][time]), 1:first(size(payload["value_function"]))) ||
                error("non-finite value function for site $(site.id)")
            all(isfinite, payload["alpha"]) && all(isfinite, payload["beta"]) ||
                error("non-finite value-function coefficients for site $(site.id)")
            all(isfinite, (payload["time"], payload["z_min"], payload["z_max"])) ||
                error("non-finite value-function metadata for site $(site.id)")
            payload["z_min"] < payload["z_max"] ||
                error("invalid value-function bounds for site $(site.id)")
            Provenance.verify_stable_file_guard(input_snapshot.manifest_guard)
            Provenance.verify_manifest_entries(input_snapshot, input_entries)
            ispath(output) && error("refusing to overwrite value function: $(output)")
            Base.Filesystem.hardlink(temporary, output)
        finally
            ispath(temporary) && rm(temporary; force=true)
        end
        return timer
    end
end  # PHASE_CODE
Core.eval(Main, PHASE_CODE)

function install_phase_code!()
    for process in workers()
        remotecall_wait(Core.eval, process, Main, PHASE_CODE)
    end
    return nothing
end

function validate_sites!(sites::Vector{EMSx.Site})
    isempty(sites) && error("site list is empty")
    ids = sort(parse.(Int, getfield.(sites, :id)))
    length(unique(ids)) == length(ids) || error("duplicate site IDs")
    length(ids) == EXPECTED_SITES ||
        error("expected $(EXPECTED_SITES) sites, found $(length(ids))")
    FORMAL && ids != collect(1:70) && error("formal runs require site IDs 1:70")
    return ids
end

function verify_input_entries!(entries)
    Provenance.verify_stable_file_guard(INPUT_SNAPSHOT.manifest_guard)
    Provenance.verify_manifest_entries(INPUT_SNAPSHOT, entries)
    return nothing
end

function phase_site_input_entries(site::EMSx.Site; simulation::Bool)
    paths = String[PRICE_PATH, METADATA_PATH, site.path_to_train_data_csv]
    simulation && push!(paths, site.path_to_test_data_csv)
    return input_entries(paths)
end

const LEGACY_VALUE_FUNCTION_SOURCE =
    joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20", "value_functions")
const LEGACY_VALUE_FUNCTION_MANIFEST =
    joinpath(ROOT, "baselines", "wdwe2_k20", "vf-manifest.tsv")
const LEGACY_SOURCE_CONTRACT =
    joinpath(ROOT, "baselines", "wdwe2_k20", "legacy-source.toml")
const LEGACY_VF_HEADER =
    "site\tpath\tbytes\tsha256\thorizon\tsoc_points\tz_points\talpha_length\tbeta_length\tz_min\tz_max"
const LOWER_SHA256 = r"^[0-9a-f]{64}$"
const CANONICAL_INTEGER = r"^(0|[1-9][0-9]*)$"

function capture_run_file_guards(run::String, manifest::String)
    return Any[
        Provenance.capture_stable_file_guard(joinpath(run, "status.toml"), ROOT),
        Provenance.capture_stable_file_guard(joinpath(run, "provenance.toml"), ROOT),
        Provenance.capture_stable_file_guard(manifest, ROOT),
    ]
end

function verify_guards!(guards)
    for guard in guards
        Provenance.verify_stable_file_guard(guard)
    end
    return nothing
end

function provenance_parameters(path::String)
    record = TOML.parsefile(path)
    haskey(record, "parameters") && record["parameters"] isa AbstractDict ||
        error("source provenance parameters are missing")
    return Dict{String,Any}(String(key) => value for (key, value) in record["parameters"])
end

function assert_status_matches_provenance!(
    status::AbstractDict,
    provenance_path::String,
    message::String,
)
    RunContract.fingerprint(provenance_parameters(provenance_path)) ==
        status["fingerprint"] || error(message)
    return nothing
end

function capture_recalibrated_source(source::String, manifest::String)
    basename(source) == "value_functions" || error("invalid recalibrated source directory")
    run = dirname(source)
    manifest == joinpath(run, "artifacts.tsv") ||
        error("invalid recalibrated source manifest location")

    # Assert completion before requiring value_functions so an interrupted calibration
    # reports its incomplete status rather than a secondary missing-directory error.
    status = RunContract.assert_complete!(run; phase="calibrate")
    source = canonical_config_path(
        source,
        "value-function source";
        existing=true,
        directory=true,
    )
    manifest = canonical_config_path(
        manifest,
        "value-function source manifest";
        existing=true,
    )
    paths_overlap(RUN_OUTPUT_DIR, source) &&
        error("output and value-function source must be disjoint")

    snapshot = Provenance.capture_manifest_snapshot(manifest, run)
    expected_paths = Set("value_functions/$(site).jld2" for site in 1:EXPECTED_SITES)
    Set(entry.path for entry in snapshot.entries) == expected_paths ||
        error("recalibrated artifact manifest has an unexpected entry set")
    provenance_path = joinpath(run, "provenance.toml")
    assert_status_matches_provenance!(
        status,
        provenance_path,
        "recalibrated source status/provenance fingerprint mismatch",
    )
    guards = capture_run_file_guards(run, manifest)
    Provenance.verify_manifest_snapshot(snapshot)
    verify_guards!(guards)

    entries = Dict{String,Any}(
        string(site) => Provenance.select_manifest_entries(
            snapshot,
            ["value_functions/$(site).jld2"],
        ) for site in 1:EXPECTED_SITES
    )
    identity = Dict{String,Any}(
        "type" => "recalibrated",
        "source" => source,
        "run" => run,
        "source_fingerprint" => status["fingerprint"],
        "status_sha256" => Provenance.sha256_file(joinpath(run, "status.toml")),
        "provenance_sha256" => Provenance.sha256_file(provenance_path),
        "manifest_sha256" => snapshot.manifest_sha256,
        "value_function_count" => EXPECTED_SITES,
    )
    return (
        kind=:recalibrated,
        source=source,
        run=run,
        manifest=manifest,
        snapshot=snapshot,
        entries=entries,
        status=status,
        guards=guards,
        worker_guards=guards,
        identity=identity,
    )
end

function strict_legacy_manifest(manifest::String)
    guard = Provenance.capture_stable_file_guard(manifest, ROOT)
    content = read(manifest, String)
    endswith(content, '\n') || error("legacy value-function manifest must end with a newline")
    lines = split(content, '\n'; keepempty=true)
    isempty(last(lines)) || error("invalid legacy value-function manifest line ending")
    pop!(lines)
    length(lines) == 71 || error("legacy value-function manifest must contain 70 rows")
    first(lines) == LEGACY_VF_HEADER || error("invalid legacy value-function manifest header")

    entries = NamedTuple{(:path, :bytes, :sha256),Tuple{String,Int,String}}[]
    rows = Dict{String,Any}()
    for (site, line) in enumerate(Iterators.drop(lines, 1))
        fields = split(line, '\t'; keepempty=true)
        length(fields) == 11 || error("invalid legacy value-function manifest row")
        site_text, relative, bytes_text, sha256, horizon_text, soc_text, z_text,
            alpha_text, beta_text, z_min_text, z_max_text = fields
        site_text == string(site) || error("legacy value-function sites must be exactly 1:70")
        relative == "results_sdp/sweep_wdwe2_k20/value_functions/$(site).jld2" ||
            error("legacy value-function path mismatch for site $(site)")
        all(text -> occursin(CANONICAL_INTEGER, text),
            (bytes_text, horizon_text, soc_text, z_text, alpha_text, beta_text)) ||
            error("invalid legacy value-function integer metadata for site $(site)")
        occursin(LOWER_SHA256, sha256) ||
            error("invalid legacy value-function SHA-256 for site $(site)")
        parse(Int, horizon_text) == 673 || error("invalid legacy horizon for site $(site)")
        parse(Int, soc_text) == 11 || error("invalid legacy SoC grid for site $(site)")
        parse(Int, z_text) == 20 || error("invalid legacy z grid for site $(site)")
        parse(Int, alpha_text) == 672 || error("invalid legacy alpha length for site $(site)")
        parse(Int, beta_text) == 672 || error("invalid legacy beta length for site $(site)")
        z_min = tryparse(Float64, z_min_text)
        z_max = tryparse(Float64, z_max_text)
        z_min !== nothing && z_max !== nothing && isfinite(z_min) && isfinite(z_max) &&
            z_min < z_max || error("invalid legacy z bounds for site $(site)")
        bytes = parse(Int, bytes_text)
        push!(entries, (path=relative, bytes=bytes, sha256=String(sha256)))
        rows[site_text] = (z_min=z_min, z_max=z_max)
    end

    snapshot = Provenance.ManifestSnapshot(
        manifest,
        ROOT,
        Provenance.sha256_file(manifest),
        Tuple(entries),
        guard,
    )
    verify_legacy_snapshot!(snapshot)
    return (snapshot=snapshot, rows=rows, guard=guard)
end

function verify_legacy_snapshot!(snapshot)
    Provenance.verify_stable_file_guard(snapshot.manifest_guard)
    Provenance.verify_manifest_entries(snapshot, snapshot.entries)
    Provenance.verify_stable_file_guard(snapshot.manifest_guard)
    return nothing
end

function validate_legacy_payloads!(legacy)
    for site in 1:70
        entry = only(Provenance.select_manifest_entries(
            legacy.snapshot,
            ["results_sdp/sweep_wdwe2_k20/value_functions/$(site).jld2"],
        ))
        path = joinpath(ROOT, split(entry.path, '/')...)
        payload = JLD2.load(path)
        required = ("value_function", "time", "alpha", "beta", "z_min", "z_max")
        all(key -> haskey(payload, key), required) ||
            error("legacy value-function payload is incomplete for site $(site)")
        size(payload["value_function"]) == (673, 11, 20) ||
            error("invalid legacy value-function shape for site $(site)")
        length(payload["alpha"]) == 672 ||
            error("invalid legacy alpha length for site $(site)")
        length(payload["beta"]) == 672 ||
            error("invalid legacy beta length for site $(site)")
        row = legacy.rows[string(site)]
        Float64(payload["z_min"]) == row.z_min &&
            Float64(payload["z_max"]) == row.z_max ||
            error("legacy value-function bounds mismatch for site $(site)")
    end
    verify_legacy_snapshot!(legacy.snapshot)
    return nothing
end

function capture_audited_legacy_source(source::String, manifest::String)
    source == LEGACY_VALUE_FUNCTION_SOURCE || error("legacy source path mismatch")
    manifest == LEGACY_VALUE_FUNCTION_MANIFEST || error("legacy manifest path mismatch")
    source = canonical_config_path(
        source,
        "value-function source";
        existing=true,
        directory=true,
    )
    manifest = canonical_config_path(
        manifest,
        "value-function source manifest";
        existing=true,
    )
    paths_overlap(RUN_OUTPUT_DIR, source) &&
        error("output and value-function source must be disjoint")

    contract_path = canonical_config_path(
        LEGACY_SOURCE_CONTRACT,
        "legacy-source.toml";
        existing=true,
    )
    contract_guard = Provenance.capture_stable_file_guard(contract_path, ROOT)
    contract = TOML.parsefile(contract_path)
    expected_keys = Set((
        "schema_version", "input_manifest_path", "input_manifest_sha256",
        "legacy_environment_lock", "legacy_log_bytes", "legacy_log_path",
        "legacy_log_sha256", "legacy_score_bytes", "legacy_score_path",
        "legacy_score_sha256", "scores_path", "scores_sha256",
        "value_function_count", "value_function_directory", "vf_manifest_path",
        "vf_manifest_sha256",
    ))
    Set(keys(contract)) == expected_keys || error("invalid audited legacy source contract fields")
    contract["schema_version"] === 1 || error("invalid audited legacy schema version")
    contract["legacy_environment_lock"] == "not_recorded_by_legacy_run" ||
        error("invalid audited legacy environment lock")
    contract["value_function_count"] === 70 ||
        error("invalid audited legacy value-function count")
    contract["value_function_directory"] ==
        "results_sdp/sweep_wdwe2_k20/value_functions" ||
        error("invalid audited legacy value-function directory")
    contract["vf_manifest_path"] == "baselines/wdwe2_k20/vf-manifest.tsv" ||
        error("invalid audited legacy manifest path")
    contract["vf_manifest_sha256"] == Provenance.sha256_file(manifest) ||
        error("invalid audited legacy manifest hash")
    contract["input_manifest_path"] == "baselines/wdwe2_k20/input-manifest.tsv" ||
        error("invalid audited legacy input manifest path")

    referenced = (
        ("input_manifest_path", "input_manifest_sha256", nothing),
        ("legacy_log_path", "legacy_log_sha256", "legacy_log_bytes"),
        ("legacy_score_path", "legacy_score_sha256", "legacy_score_bytes"),
        ("scores_path", "scores_sha256", nothing),
        ("vf_manifest_path", "vf_manifest_sha256", nothing),
    )
    audit_guards = Any[contract_guard]
    for (path_key, hash_key, bytes_key) in referenced
        path = canonical_config_path(contract[path_key], path_key; existing=true)
        Provenance.sha256_file(path) == contract[hash_key] ||
            error("audited legacy hash mismatch for $(path_key)")
        if bytes_key !== nothing
            filesize(path) == contract[bytes_key] ||
                error("audited legacy byte count mismatch for $(path_key)")
        end
        push!(audit_guards, Provenance.capture_stable_file_guard(path, ROOT))
    end

    legacy = strict_legacy_manifest(manifest)
    validate_legacy_payloads!(legacy)
    verify_guards!(audit_guards)
    entries = Dict{String,Any}(
        string(site) => Provenance.select_manifest_entries(
            legacy.snapshot,
            ["results_sdp/sweep_wdwe2_k20/value_functions/$(site).jld2"],
        ) for site in 1:EXPECTED_SITES
    )
    identity = Dict{String,Any}(
        "type" => "audited_legacy",
        "source" => source,
        "manifest_sha256" => legacy.snapshot.manifest_sha256,
        "legacy_contract_sha256" => Provenance.sha256_file(contract_path),
        "value_function_count" => 70,
        "source_fingerprint" => contract["vf_manifest_sha256"],
    )
    return (
        kind=:audited_legacy,
        source=source,
        run=nothing,
        manifest=manifest,
        snapshot=legacy.snapshot,
        entries=entries,
        status=nothing,
        guards=audit_guards,
        worker_guards=Any[contract_guard, legacy.guard],
        identity=identity,
    )
end

function capture_value_function_source()
    isempty(VALUE_FUNCTION_SOURCE_SETTING) &&
        error("VALUE_FUNCTION_SOURCE_DIR is required")
    isempty(VALUE_FUNCTION_MANIFEST_SETTING) &&
        error("VALUE_FUNCTION_MANIFEST is required")

    source = try
        canonical_config_path(
            VALUE_FUNCTION_SOURCE_SETTING,
            "value-function source";
            existing=false,
            directory=true,
        )
    catch
        error("value-function source is not an accepted recalibrated or audited legacy source")
    end
    manifest = try
        canonical_config_path(
            VALUE_FUNCTION_MANIFEST_SETTING,
            "value-function source manifest";
            existing=false,
        )
    catch
        error("value-function source is not an accepted recalibrated or audited legacy source")
    end

    if source == LEGACY_VALUE_FUNCTION_SOURCE &&
       manifest == LEGACY_VALUE_FUNCTION_MANIFEST
        return capture_audited_legacy_source(source, manifest)
    end
    run = dirname(source)
    if basename(source) == "value_functions" &&
       manifest == joinpath(run, "artifacts.tsv") &&
       isfile(joinpath(run, "status.toml"))
        return capture_recalibrated_source(source, manifest)
    end
    error("value-function source is not an accepted recalibrated or audited legacy source")
end

function verify_value_function_source!(sealed)
    if sealed.kind == :recalibrated
        status = RunContract.assert_complete!(sealed.run; phase="calibrate")
        status == sealed.status || error("recalibrated source status changed")
        assert_status_matches_provenance!(
            status,
            joinpath(sealed.run, "provenance.toml"),
            "recalibrated source status/provenance fingerprint mismatch",
        )
    end
    verify_guards!(sealed.guards)
    if sealed.kind == :audited_legacy
        verify_legacy_snapshot!(sealed.snapshot)
    else
        Provenance.verify_manifest_snapshot(sealed.snapshot)
    end
    return nothing
end

function capture_simulation_source()
    isempty(SIMULATION_SOURCE_SETTING) && error("SIMULATION_SOURCE_DIR is required")
    source = canonical_config_path(
        SIMULATION_SOURCE_SETTING,
        "simulation source";
        existing=true,
        directory=true,
    )
    paths_overlap(RUN_OUTPUT_DIR, source) &&
        error("output and simulation source must be disjoint")
    status = RunContract.assert_complete!(source; phase="simulate")
    manifest = canonical_config_path(
        joinpath(source, status["artifact_manifest"]),
        "simulation source manifest";
        existing=true,
    )
    snapshot = Provenance.capture_manifest_snapshot(manifest, source)
    expected_paths = Set(vcat(
        ["$(site).jld2" for site in 1:EXPECTED_SITES],
        ["score.jld2"],
    ))
    Set(entry.path for entry in snapshot.entries) == expected_paths ||
        error("simulation source artifact manifest has an unexpected entry set")
    provenance_path = joinpath(source, "provenance.toml")
    assert_status_matches_provenance!(
        status,
        provenance_path,
        "simulation source status/provenance fingerprint mismatch",
    )
    guards = capture_run_file_guards(source, manifest)
    Provenance.verify_manifest_snapshot(snapshot)
    verify_guards!(guards)
    score_entry = Provenance.select_manifest_entries(snapshot, ["score.jld2"])
    identity = Dict{String,Any}(
        "type" => "strict_complete_simulation",
        "source" => source,
        "source_fingerprint" => status["fingerprint"],
        "status_sha256" => Provenance.sha256_file(joinpath(source, "status.toml")),
        "provenance_sha256" => Provenance.sha256_file(provenance_path),
        "manifest_sha256" => snapshot.manifest_sha256,
        "artifact_count" => length(snapshot.entries),
    )
    return (
        source=source,
        manifest=manifest,
        snapshot=snapshot,
        status=status,
        guards=guards,
        score_entry=score_entry,
        identity=identity,
    )
end

function verify_simulation_source!(sealed)
    status = RunContract.assert_complete!(sealed.source; phase="simulate")
    status == sealed.status || error("simulation source status changed")
    assert_status_matches_provenance!(
        status,
        joinpath(sealed.source, "provenance.toml"),
        "simulation source status/provenance fingerprint mismatch",
    )
    verify_guards!(sealed.guards)
    Provenance.verify_manifest_snapshot(sealed.snapshot)
    return nothing
end

function atomic_install_noreplace!(temporary::String, output::String)
    dirname(temporary) == STAGING_NAMESPACE ||
        error("atomic install must use the Task 5 sibling staging namespace")
    ispath(output) && error("refusing to overwrite final artifact: $(output)")
    Base.Filesystem.hardlink(temporary, output)
    return nothing
end

function with_private_temp(f::Function)
    islink(STAGING_NAMESPACE) &&
        error("artifact staging namespace must not be a symlink: $(STAGING_NAMESPACE)")
    mkpath(STAGING_NAMESPACE)
    temporary, io = mktemp(STAGING_NAMESPACE)
    close(io)
    try
        return f(temporary)
    finally
        ispath(temporary) && rm(temporary; force=true)
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Parallel Calibration
# ══════════════════════════════════════════════════════════════════════════════
function validate_value_function_output!(output::String, site_id::String)
    isfile(output) || error("missing calibrated value function: $(output)")
    payload = JLD2.load(output)
    required = ("value_function", "time", "alpha", "beta", "z_min", "z_max")
    all(key -> haskey(payload, key), required) ||
        error("incomplete value-function output for site $(site_id)")
    expected_shape = (horizon + 1, length(0.0:dx:1.0), NZ)
    size(payload["value_function"]) == expected_shape ||
        error("invalid value-function shape for site $(site_id)")
    length(payload["alpha"]) == horizon ||
        error("invalid alpha length for site $(site_id)")
    length(payload["beta"]) == horizon ||
        error("invalid beta length for site $(site_id)")
    value_function = payload["value_function"]
    all(time -> all(isfinite, value_function[time]), 1:first(size(value_function))) ||
        error("non-finite value function for site $(site_id)")
    all(isfinite, payload["alpha"]) || error("non-finite alpha for site $(site_id)")
    all(isfinite, payload["beta"]) || error("non-finite beta for site $(site_id)")
    all(isfinite, (payload["time"], payload["z_min"], payload["z_max"])) ||
        error("non-finite value-function metadata for site $(site_id)")
    payload["z_min"] < payload["z_max"] ||
        error("invalid value-function bounds for site $(site_id)")
    return Float64(payload["time"])
end

function calibrate_sites_parallel(path_to_save_folder, path_to_price_csv,
                                  path_to_metadata_csv, path_to_train_data;
                                  resume::Bool=false)
    @info "Phase 1/3: SDP-AR(1) A₂ calibration — $(nworkers()) workers, batch_size=1"

    value_function_dir = joinpath(path_to_save_folder, "value_functions")
    mkpath(value_function_dir)
    prices = EMSx.load_prices(path_to_price_csv)
    sites = EMSx.load_sites(
        path_to_metadata_csv,
        nothing,
        path_to_train_data,
        path_to_save_folder,
    )
    validate_sites!(sites)
    entries_by_site = Dict(
        site.id => phase_site_input_entries(site; simulation=false) for site in sites
    )

    pending = Int[]
    results = Float64[]
    for (index, site) in pairs(sites)
        output = joinpath(value_function_dir, site.id * ".jld2")
        if ispath(output)
            resume || error("refusing to overwrite value function: $(output)")
            verify_input_entries!(entries_by_site[site.id])
            push!(results, validate_value_function_output!(output, site.id))
            verify_input_entries!(entries_by_site[site.id])
        else
            push!(pending, index)
        end
    end

    n_sites = length(sites)
    @info "$n_sites sites to calibrate (A₂: periodic VI, max $MAX_VI_ITERS iters)"
    elapsed = @elapsed begin
        if !isempty(pending)
            computed = @showprogress "  Calibrating (A₂ periodic VI): " pmap(
                pending;
                batch_size=1,
            ) do index
                site = sites[index]
                output = joinpath(value_function_dir, site.id * ".jld2")
                calibrate_site_atomic!(
                    site,
                    prices,
                    output,
                    INPUT_SNAPSHOT,
                    entries_by_site[site.id],
                )
            end
            append!(results, computed)
        end
    end

    for site in sites
        output = joinpath(value_function_dir, site.id * ".jld2")
        verify_input_entries!(entries_by_site[site.id])
        validate_value_function_output!(output, site.id)
        verify_input_entries!(entries_by_site[site.id])
    end

    @info "Calibration done: $(round(elapsed, digits=1))s total, " *
          "$(round(mean(results), digits=1))s/site avg, " *
          "min=$(round(minimum(results), digits=1))s max=$(round(maximum(results), digits=1))s"
    return nothing
end

function validate_simulations!(
    simulations,
    site_id::String;
    expected_horizons::Union{Nothing,Dict{String,Int}}=nothing,
)
    simulations isa AbstractVector && !isempty(simulations) ||
        error("invalid simulation output for site $(site_id)")
    all(simulation -> simulation.id.site_id == site_id, simulations) ||
        error("simulation site ID mismatch for site $(site_id)")
    period_ids = getfield.(getfield.(simulations, :id), :period_id)
    length(unique(period_ids)) == length(period_ids) ||
        error("duplicate simulation periods for site $(site_id)")
    if expected_horizons !== nothing
        Set(period_ids) == Set(keys(expected_horizons)) ||
            error("simulation period set mismatch for site $(site_id)")
    end
    for simulation in simulations
        result = simulation.result
        !isempty(result.cost) || error("empty simulation result for site $(site_id)")
        length(result.cost) == length(result.soc) == length(result.control) ||
            error("inconsistent simulation result lengths for site $(site_id)")
        length(simulation.timer) == length(result.cost) ||
            error("inconsistent simulation timer length for site $(site_id)")
        if expected_horizons !== nothing
            length(result.cost) == expected_horizons[simulation.id.period_id] ||
                error("simulation horizon mismatch for site $(site_id)")
        end
        all(isfinite, result.cost) &&
            all(isfinite, result.soc) &&
            all(isfinite, result.control) &&
            all(isfinite, simulation.timer) ||
            error("non-finite simulation values for site $(site_id)")
        all(soc -> 0.0 <= soc <= 1.0, result.soc) ||
            error("simulation state of charge is out of bounds for site $(site_id)")
        all(timer -> timer >= 0.0, simulation.timer) ||
            error("negative simulation timer for site $(site_id)")
    end
    return simulations
end

function validate_simulation_output!(
    path::String,
    site_id::String;
    expected_horizons::Union{Nothing,Dict{String,Int}}=nothing,
)
    isfile(path) || error("missing simulation for site $(site_id)")
    simulations = JLD2.load(path, "simulations")
    return validate_simulations!(
        simulations,
        site_id;
        expected_horizons=expected_horizons,
    )
end

function validate_existing_simulation_output!(
    path::String,
    site_id::String;
    expected_horizons::Dict{String,Int},
)
    try
        return validate_simulation_output!(
            path,
            site_id;
            expected_horizons=expected_horizons,
        )
    catch err
        error("invalid existing simulation artifact for site $(site_id): $(sprint(showerror, err))")
    end
end

function expected_horizons_from_test_data(path::String)
    counts = Dict{String,Int}()
    for row in CSV.File(path; select=[:period_id])
        period_id = string(row.period_id)
        counts[period_id] = get(counts, period_id, 0) + 1
    end
    isempty(counts) && error("test data contains no periods: $(path)")
    horizons = Dict(period_id => count - 96 for (period_id, count) in counts)
    all(horizon -> horizon > 0, values(horizons)) ||
        error("test data contains a non-positive simulation horizon: $(path)")
    return horizons
end

function simulation_signature(simulations)
    return [
        (
            site_id=simulation.id.site_id,
            period_id=simulation.id.period_id,
            price_id=simulation.id.price_id,
            model_type=simulation.id.model_type,
            cost=simulation.result.cost,
            soc=simulation.result.soc,
            control=simulation.result.control,
            timer=simulation.timer,
        ) for simulation in simulations
    ]
end

function group_all_simulations_preserving!(
    sites::Vector{EMSx.Site};
    verify_sources::Function=() -> nothing,
)
    isempty(sites) && error("cannot group an empty site list")
    ids = sort(parse.(Int, getfield.(sites, :id)))
    length(unique(ids)) == length(ids) || error("duplicate site IDs")

    scores = Dict{String,Any}()
    for site in sites
        path = joinpath(site.path_to_save_folder, site.id * ".jld2")
        scores[site.id] = validate_simulation_output!(path, site.id)
    end

    output = joinpath(first(sites).path_to_save_folder, "score.jld2")
    ispath(output) && error("refusing to overwrite grouped score: $(output)")
    with_private_temp() do temporary
        write_jld2_payload!(temporary, scores)
        validate_grouped_score!(temporary, sites)
        verify_sources()
        atomic_install_noreplace!(temporary, output)
    end
    return output
end

function validate_grouped_score!(output::String, sites::Vector{EMSx.Site})
    isfile(output) || error("missing grouped simulation score: $(output)")
    scores = JLD2.load(output)
    expected_ids = Set(getfield.(sites, :id))
    Set(string.(keys(scores))) == expected_ids ||
        error("grouped score site IDs do not match simulation sites")
    for site in sites
        grouped = validate_simulations!(scores[site.id], site.id)
        per_site = validate_simulation_output!(
            joinpath(site.path_to_save_folder, site.id * ".jld2"),
            site.id,
        )
        isequal(simulation_signature(grouped), simulation_signature(per_site)) ||
            error("grouped score differs from per-site simulation $(site.id)")
    end
    return nothing
end

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: Parallel Simulation (continuous SOC across periods)
# ══════════════════════════════════════════════════════════════════════════════
function simulate_sites_parallel(sealed_vf, path_to_save_folder, path_to_price_csv,
                                 path_to_metadata_csv, path_to_test_data,
                                 path_to_train_data; resume::Bool=false)
    @info "Phase 2/3: Simulation (continuous SOC) — $(nworkers()) workers, work-stealing"
    verify_value_function_source!(sealed_vf)

    prices = EMSx.load_prices(path_to_price_csv)
    sites = EMSx.load_sites(
        path_to_metadata_csv,
        path_to_test_data,
        path_to_train_data,
        path_to_save_folder,
    )
    validate_sites!(sites)
    entries_by_site = Dict(
        site.id => phase_site_input_entries(site; simulation=true) for site in sites
    )

    pending = EMSx.Site[]
    expected_horizons_by_site = Dict{String,Dict{String,Int}}()
    for site in sites
        output = joinpath(path_to_save_folder, site.id * ".jld2")
        if ispath(output)
            resume || error("refusing to overwrite simulation: $(output)")
            expected_horizons = expected_horizons_from_test_data(
                site.path_to_test_data_csv,
            )
            expected_horizons_by_site[site.id] = expected_horizons
            verify_input_entries!(entries_by_site[site.id])
            Provenance.verify_manifest_entries(
                sealed_vf.snapshot,
                sealed_vf.entries[site.id],
            )
            validate_existing_simulation_output!(
                output,
                site.id;
                expected_horizons=expected_horizons,
            )
            verify_input_entries!(entries_by_site[site.id])
            verify_guards!(sealed_vf.worker_guards)
            Provenance.verify_manifest_entries(
                sealed_vf.snapshot,
                sealed_vf.entries[site.id],
            )
        else
            push!(pending, site)
        end
    end

    to_do = length(pending)
    @sync begin
        for worker in workers()
            @async begin
                while true
                    index = to_do
                    to_do -= 1
                    index <= 0 && break
                    site = pending[index]
                    println(
                        "processing a new job - jobs left in queue : " *
                        "$(index - 1) / $(length(pending))",
                    )
                    verify_input_entries!(entries_by_site[site.id])
                    controller = SdpAr1A2(
                        sealed_vf.source,
                        sealed_vf.snapshot,
                        sealed_vf.entries[site.id],
                        sealed_vf.worker_guards,
                    )
                    result = remotecall_fetch(
                        simulate_site_continuous,
                        worker,
                        controller,
                        site,
                        prices,
                    )
                    output = joinpath(path_to_save_folder, site.id * ".jld2")
                    with_private_temp() do temporary
                        write_jld2_payload!(
                            temporary,
                            Dict("simulations" => result.simulations),
                        )
                        validate_simulation_output!(
                            temporary,
                            site.id;
                            expected_horizons=result.expected_horizons,
                        )
                        verify_input_entries!(entries_by_site[site.id])
                        verify_guards!(sealed_vf.worker_guards)
                        Provenance.verify_manifest_entries(
                            sealed_vf.snapshot,
                            sealed_vf.entries[site.id],
                        )
                        atomic_install_noreplace!(temporary, output)
                    end
                    expected_horizons_by_site[site.id] = result.expected_horizons
                end
            end
        end
    end

    for site in sites
        verify_input_entries!(entries_by_site[site.id])
        validate_simulation_output!(
            joinpath(path_to_save_folder, site.id * ".jld2"),
            site.id;
            expected_horizons=expected_horizons_by_site[site.id],
        )
        verify_input_entries!(entries_by_site[site.id])
    end

    verify_sources = () -> begin
        Provenance.verify_manifest_snapshot(INPUT_SNAPSHOT)
        verify_value_function_source!(sealed_vf)
    end
    development_fail_if_present!(
        "fail_before_score_file",
        "development fail-before-score hook",
    )
    score = joinpath(path_to_save_folder, "score.jld2")
    if ispath(score)
        resume || error("refusing to overwrite grouped score: $(score)")
        isempty(pending) || error("grouped score predates resumed per-site outputs")
        verify_sources()
        validate_grouped_score!(score, sites)
        verify_sources()
    else
        score = group_all_simulations_preserving!(sites; verify_sources=verify_sources)
    end
    validate_grouped_score!(score, sites)
    verify_value_function_source!(sealed_vf)
    @info "Simulation complete."
    return nothing
end

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Evaluation
# ══════════════════════════════════════════════════════════════════════════════
function validate_metrics!(metrics::DataFrame)
    names(metrics) == ["site", "cost", "gain", "score"] ||
        error("invalid metrics schema")
    ids = parse.(Int, string.(metrics.site))
    length(unique(ids)) == length(ids) || error("duplicate metric site IDs")
    length(ids) == EXPECTED_SITES ||
        error("expected $(EXPECTED_SITES) metric rows, found $(length(ids))")
    FORMAL && ids != collect(1:70) && error("formal evaluation requires site IDs 1:70")
    all(isfinite, metrics.cost) &&
        all(isfinite, metrics.gain) &&
        all(isfinite, metrics.score) || error("metrics contain non-finite values")
    return ids
end

function verify_simulation_score_source!(sealed_simulation)
    verify_simulation_source!(sealed_simulation)
    Provenance.verify_manifest_entries(
        sealed_simulation.snapshot,
        sealed_simulation.score_entry,
    )
    return nothing
end

function compute_evaluation_metrics(sealed_simulation)
    score_file = joinpath(sealed_simulation.source, "score.jld2")
    isfile(score_file) || error("score file not found: $(score_file)")
    verify_simulation_score_source!(sealed_simulation)
    metrics = EMSx.evaluate_model(score_file)
    verify_simulation_score_source!(sealed_simulation)
    order = sortperm(parse.(Int, string.(metrics.site)))
    metrics = metrics[order, :]
    validate_metrics!(metrics)
    return metrics
end

function validate_metrics_file!(metrics_path::String, expected::DataFrame)
    isfile(metrics_path) || error("metrics output is missing: $(metrics_path)")
    written = CSV.read(
        metrics_path,
        DataFrame;
        stringtype=String,
        types=Dict(:site => String),
    )
    validate_metrics!(written)
    all(name -> written[!, name] == expected[!, name], names(expected)) ||
        error("metrics output does not match simulation source")
    return nothing
end

function validate_evaluation_output!(sealed_simulation, evaluation_output::String)
    metrics_path = joinpath(evaluation_output, "metrics.csv")
    expected = compute_evaluation_metrics(sealed_simulation)
    validate_metrics_file!(metrics_path, expected)
    verify_simulation_score_source!(sealed_simulation)
    return nothing
end

function evaluate_results(sealed_simulation, evaluation_output)
    @info "Phase 3/3: Evaluation..."

    metrics_path = joinpath(evaluation_output, "metrics.csv")
    ispath(metrics_path) && error("refusing to overwrite metrics: $(metrics_path)")
    metrics = compute_evaluation_metrics(sealed_simulation)
    with_private_temp() do temporary
        CSV.write(temporary, metrics)
        validate_metrics_file!(temporary, metrics)
        verify_simulation_score_source!(sealed_simulation)
        atomic_install_noreplace!(temporary, metrics_path)
    end

    println("\n" * "="^60)
    println("  SDP-AR(1) A₂ (Periodic Average-Cost SDP) Results")
    println("="^60)
    show(stdout, "text/plain", describe(metrics))
    println("\n")
    println("  Mean Score: $(round(mean(metrics.score), digits=4))")
    println("  Mean Gain:  $(round(mean(metrics.gain), digits=2))")
    println("  Mean Cost:  $(round(mean(metrics.cost), digits=2))")
    println("="^60)
    return metrics
end

function ensure_phase_provenance!(run_config::Dict, reservation::Symbol)
    output = joinpath(RUN_OUTPUT_DIR, "provenance.toml")
    vf_manifest = PHASE == :simulate ? VALUE_FUNCTION_MANIFEST_SETTING : nothing
    if !ispath(output)
        if reservation == :resume
            unexpected = filter(name -> name != "status.toml", readdir(RUN_OUTPUT_DIR))
            isempty(unexpected) || error(
                "cannot recreate missing provenance after artifacts exist: $(unexpected)",
            )
        end
        Provenance.capture_provenance(
            output;
            root=ROOT,
            phase=String(PHASE),
            tag=TAG,
            run_id=RUN_ID,
            parameters=run_config,
            input_manifest=INPUT_MANIFEST,
            vf_manifest=vf_manifest,
            staging_directory=STAGING_NAMESPACE,
        )
    else
        reservation == :resume || error("provenance output already exists: $(output)")
    end

    record = TOML.parsefile(output)
    record["phase"] == String(PHASE) || error("provenance phase mismatch")
    record["tag"] == TAG || error("provenance tag mismatch")
    record["run_id"] == RUN_ID || error("provenance run ID mismatch")
    record["parameters"] == run_config || error("provenance parameters mismatch")
    record["input_manifest"] == relpath(INPUT_MANIFEST, ROOT) ||
        error("provenance input manifest mismatch")
    record["input_manifest_sha256"] == Provenance.sha256_file(INPUT_MANIFEST) ||
        error("provenance input manifest hash mismatch")

    expected_vf_path = vf_manifest === nothing ? "" : relpath(vf_manifest, ROOT)
    expected_vf_hash =
        vf_manifest === nothing ? "" : Provenance.sha256_file(vf_manifest)
    record["vf_manifest"] == expected_vf_path ||
        error("provenance value-function manifest mismatch")
    record["vf_manifest_sha256"] == expected_vf_hash ||
        error("provenance value-function manifest hash mismatch")

    outer = Provenance.git_state(ROOT)
    nested = Provenance.git_state(joinpath(ROOT, "EMSx.jl"))
    record["outer_git_sha"] == outer.sha || error("provenance outer Git SHA mismatch")
    record["nested_git_sha"] == nested.sha ||
        error("provenance nested Git SHA mismatch")
    record["outer_git_dirty"] == outer.dirty ||
        error("provenance outer Git dirty-state mismatch")
    record["nested_git_dirty"] == nested.dirty ||
        error("provenance nested Git dirty-state mismatch")
    record["project_sha256"] == Provenance.sha256_file(joinpath(ROOT, "Project.toml")) ||
        error("provenance Project.toml hash mismatch")
    record["manifest_sha256"] == Provenance.sha256_file(joinpath(ROOT, "Manifest.toml")) ||
        error("provenance Manifest.toml hash mismatch")
    record["julia_version"] == string(VERSION) ||
        error("provenance Julia version mismatch")
    record["cpu_name"] == Sys.CPU_NAME || error("provenance CPU name mismatch")
    record["cpu_threads"] == Sys.CPU_THREADS ||
        error("provenance CPU thread count mismatch")
    record["julia_threads"] == Threads.nthreads() ||
        error("provenance Julia thread count mismatch")
    record["blas_threads"] == LinearAlgebra.BLAS.get_num_threads() ||
        error("provenance BLAS thread count mismatch")
    record["blas_config"] == sprint(show, LinearAlgebra.BLAS.get_config()) ||
        error("provenance BLAS configuration mismatch")
    record["active_project"] == Base.active_project() ||
        error("provenance active project mismatch")
    record["emsx_path"] == pathof(EMSx) || error("provenance EMSx path mismatch")
    record["load_path"] == LOAD_PATH || error("provenance LOAD_PATH mismatch")

    captured_workers = record["workers"]
    length(captured_workers) == length(workers()) ||
        error("provenance worker count mismatch")
    for (worker, captured) in zip(workers(), captured_workers)
        current = remotecall_fetch(
            Core.eval,
            worker,
            Main,
            quote
                using EMSx
                Dict(
                    "project" => Base.active_project(),
                    "emsx" => pathof(EMSx),
                    "load_path" => copy(LOAD_PATH),
                )
            end,
        )
        captured["project"] == current["project"] ||
            error("provenance worker project mismatch")
        captured["emsx"] == current["emsx"] ||
            error("provenance worker EMSx path mismatch")
        captured["load_path"] == current["load_path"] ||
            error("provenance worker LOAD_PATH mismatch")
    end

    FORMAL && (record["outer_git_dirty"] || record["nested_git_dirty"]) &&
        error("formal provenance captured dirty sources")
    return nothing
end

function verify_master_provenance!(run_config::Dict)
    output = canonical_config_path(
        joinpath(RUN_OUTPUT_DIR, "provenance.toml"),
        "phase provenance";
        existing=true,
    )
    guard = Provenance.capture_stable_file_guard(output, ROOT)
    record = TOML.parsefile(output)
    record["phase"] == String(PHASE) || error("provenance phase mismatch")
    record["tag"] == TAG || error("provenance tag mismatch")
    record["run_id"] == RUN_ID || error("provenance run ID mismatch")
    record["parameters"] == run_config || error("provenance parameters mismatch")
    record["input_manifest"] == relpath(INPUT_MANIFEST, ROOT) ||
        error("provenance input manifest mismatch")
    record["input_manifest_sha256"] == Provenance.sha256_file(INPUT_MANIFEST) ||
        error("provenance input manifest hash mismatch")

    vf_manifest = PHASE == :simulate ? VALUE_FUNCTION_MANIFEST_SETTING : nothing
    expected_vf_path = vf_manifest === nothing ? "" : relpath(vf_manifest, ROOT)
    expected_vf_hash =
        vf_manifest === nothing ? "" : Provenance.sha256_file(vf_manifest)
    record["vf_manifest"] == expected_vf_path ||
        error("provenance value-function manifest mismatch")
    record["vf_manifest_sha256"] == expected_vf_hash ||
        error("provenance value-function manifest hash mismatch")
    record["project_sha256"] == Provenance.sha256_file(joinpath(ROOT, "Project.toml")) ||
        error("provenance Project.toml hash mismatch")
    record["manifest_sha256"] == Provenance.sha256_file(joinpath(ROOT, "Manifest.toml")) ||
        error("provenance Manifest.toml hash mismatch")
    record["julia_version"] == string(VERSION) || error("provenance Julia version mismatch")
    record["active_project"] == Base.active_project() ||
        error("provenance active project mismatch")
    record["emsx_path"] == pathof(EMSx) || error("provenance EMSx path mismatch")
    record["load_path"] == LOAD_PATH || error("provenance LOAD_PATH mismatch")
    length(record["workers"]) == N_WORKERS || error("provenance worker count mismatch")

    outer = Provenance.git_state(ROOT)
    nested = Provenance.git_state(joinpath(ROOT, "EMSx.jl"))
    record["outer_git_sha"] == outer.sha || error("provenance outer Git SHA mismatch")
    record["nested_git_sha"] == nested.sha || error("provenance nested Git SHA mismatch")
    record["outer_git_dirty"] == outer.dirty ||
        error("provenance outer Git dirty-state mismatch")
    record["nested_git_dirty"] == nested.dirty ||
        error("provenance nested Git dirty-state mismatch")
    if FORMAL
        !outer.dirty && !nested.dirty || error("formal sources changed during the run")
        outer.sha == FORMAL_OUTER_START.sha && nested.sha == FORMAL_NESTED_START.sha ||
            error("formal source Git SHA changed during the run")
    end
    Provenance.verify_stable_file_guard(guard)
    return nothing
end

function verify_after_worker_cleanup!(
    run_config::Dict,
    sealed_vf,
    sealed_simulation,
    artifact_manifest::String,
)
    Provenance.verify_manifest_snapshot(INPUT_SNAPSHOT)
    Provenance.verify_stable_file_guard(CONFIG_GUARD)
    verify_master_provenance!(run_config)
    Provenance.verify_file_manifest(
        joinpath(RUN_OUTPUT_DIR, artifact_manifest),
        RUN_OUTPUT_DIR,
    )
    if PHASE == :simulate
        verify_value_function_source!(sealed_vf)
    elseif PHASE == :evaluate
        try
            verify_simulation_source!(sealed_simulation)
        catch err
            error("simulation source changed after worker cleanup: $(sprint(showerror, err))")
        end
    end
    return nothing
end

function phase_artifact_files()
    if PHASE == :calibrate
        return [
            joinpath(RUN_OUTPUT_DIR, "value_functions", "$(site).jld2") for
            site in 1:EXPECTED_SITES
        ]
    elseif PHASE == :simulate
        return vcat(
            [joinpath(RUN_OUTPUT_DIR, "$(site).jld2") for site in 1:EXPECTED_SITES],
            [joinpath(RUN_OUTPUT_DIR, "score.jld2")],
        )
    end
    return [joinpath(RUN_OUTPUT_DIR, "metrics.csv")]
end

function ensure_artifact_manifest!(reservation::Symbol)
    files = phase_artifact_files()
    all(isfile, files) || error("phase artifact set is incomplete")
    output = joinpath(RUN_OUTPUT_DIR, "artifacts.tsv")
    if ispath(output)
        reservation == :resume || error("artifact manifest already exists: $(output)")
    else
        Provenance.write_file_manifest(
            output,
            files,
            RUN_OUTPUT_DIR;
            staging_directory=STAGING_NAMESPACE,
        )
    end
    snapshot = Provenance.capture_manifest_snapshot(output, RUN_OUTPUT_DIR)
    expected = Set(replace(relpath(path, RUN_OUTPUT_DIR), '\\' => '/') for path in files)
    Set(entry.path for entry in snapshot.entries) == expected ||
        error("artifact manifest does not exactly cover the phase artifact set")
    Provenance.verify_manifest_snapshot(snapshot)

    expected_files = Set(vcat(
        files,
        [
            joinpath(RUN_OUTPUT_DIR, "status.toml"),
            joinpath(RUN_OUTPUT_DIR, "provenance.toml"),
            output,
        ],
    ))
    actual_files = Set{String}()
    for (directory, _, names) in walkdir(RUN_OUTPUT_DIR)
        for name in names
            push!(actual_files, joinpath(directory, name))
        end
    end
    actual_files == expected_files || error("run directory contains unexpected artifacts")
    return "artifacts.tsv"
end

# ══════════════════════════════════════════════════════════════════════════════
# Locked single-phase dispatch
# ══════════════════════════════════════════════════════════════════════════════
function build_run_config(sealed_vf, sealed_simulation; unsealed::Bool=false)
    run_config = Dict{String,Any}(
        "phase" => String(PHASE),
        "tag" => TAG,
        "run_id" => RUN_ID,
        "parameters" =>
            Dict{String,Any}(String(key) => value for (key, value) in PARAMETERS),
        "experiment_config" => deepcopy(CONFIG),
        "value_function_source_dir" => VALUE_FUNCTION_SOURCE_SETTING,
        "value_function_manifest" => VALUE_FUNCTION_MANIFEST_SETTING,
        "simulation_source_dir" => SIMULATION_SOURCE_SETTING,
    )
    if PHASE == :simulate
        run_config["value_function_source_identity"] = unsealed ? Dict{String,Any}(
            "type" => "unsealed",
            "source" => VALUE_FUNCTION_SOURCE_SETTING,
            "manifest" => VALUE_FUNCTION_MANIFEST_SETTING,
        ) : deepcopy(sealed_vf.identity)
    elseif PHASE == :evaluate
        run_config["simulation_source_identity"] = unsealed ? Dict{String,Any}(
            "type" => "unsealed",
            "source" => SIMULATION_SOURCE_SETTING,
        ) : deepcopy(sealed_simulation.identity)
    end
    return run_config
end

function main()
    canonical_config_path(
        RUN_OUTPUT_DIR,
        "phase output";
        existing=false,
        directory=true,
    ) == RUN_OUTPUT_DIR || error("phase output path is not canonical")
    resume = get(ENV, "RESUME_INCOMPLETE", "false") == "true"

    RunContract.with_run_lock(RUN_OUTPUT_DIR) do lease
        sealed_vf = nothing
        sealed_simulation = nothing
        try
            sealed_vf = PHASE == :simulate ? capture_value_function_source() : nothing
            sealed_simulation =
                PHASE == :evaluate ? capture_simulation_source() : nothing
        catch err
            failed_config = build_run_config(nothing, nothing; unsealed=true)
            RunContract.reserve_run!(lease, failed_config; resume=resume)
            rethrow()
        end

        run_config = build_run_config(sealed_vf, sealed_simulation)
        reservation = RunContract.reserve_run!(lease, run_config; resume=resume)
        development_fail_if_present!(
            "fail_before_provenance_file",
            "development fail-before-provenance hook",
        )

        artifact_manifest = EnvironmentIdentity.with_workers_checked(ROOT, N_WORKERS) do worker_ids
            install_phase_code!()
            @info "Running with $(length(worker_ids)) checked workers"
            ensure_phase_provenance!(run_config, reservation)
            development_fail_if_present!(
                "fail_before_work_file",
                "development fail-before-work hook",
            )

            if PHASE == :calibrate
                calibrate_sites_parallel(
                    RUN_OUTPUT_DIR,
                    PRICE_PATH,
                    METADATA_PATH,
                    TRAIN_PATH;
                    resume=reservation == :resume,
                )
            elseif PHASE == :simulate
                simulate_sites_parallel(
                    sealed_vf,
                    RUN_OUTPUT_DIR,
                    PRICE_PATH,
                    METADATA_PATH,
                    TEST_PATH,
                    TRAIN_PATH;
                    resume=reservation == :resume,
                )
            else
                metrics_path = joinpath(RUN_OUTPUT_DIR, "metrics.csv")
                if reservation == :resume && ispath(metrics_path)
                    validate_evaluation_output!(sealed_simulation, RUN_OUTPUT_DIR)
                else
                    evaluate_results(sealed_simulation, RUN_OUTPUT_DIR)
                end
                # The post-publication source check runs only after checked-worker
                # teardown, so all mutations in that boundary receive one fail-closed
                # diagnostic from verify_after_worker_cleanup!.
            end

            Provenance.verify_manifest_snapshot(INPUT_SNAPSHOT)
            Provenance.verify_stable_file_guard(CONFIG_GUARD)
            artifact_manifest = ensure_artifact_manifest!(reservation)
            Provenance.verify_file_manifest(
                joinpath(RUN_OUTPUT_DIR, artifact_manifest),
                RUN_OUTPUT_DIR,
            )
            return artifact_manifest
        end

        verify_after_worker_cleanup!(
            run_config,
            sealed_vf,
            sealed_simulation,
            artifact_manifest,
        )
        development_pause_after_cleanup!()
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
