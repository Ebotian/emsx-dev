#!/usr/bin/env julia
# ============================================================================
# EMSx SDP-AR(1) — 12-Worker Parallel (Hyperthreading)
# ============================================================================
# Usage: julia sdp_ar1_parallel.jl
#
# Algorithm: SDP with AR(1) noise model on net demand (§5.2.2 of paper)
#   - Extended state: (soc, z_t) where z_t = most recent net demand
#   - AR(1) dynamics: z_{t+1} = α_t·z_t + β_t + ε_{t+1}
#   - Cost uses AR(1) prediction: net_demand = α_t·z_t + β_t + ε
#
# Hardware: Ryzen 5 9600X (6C/12T, 32GB RAM)
# Strategy:  12 workers = 1 per logical thread (hyperthreading fills
#            memory-access stalls in SDP inner loop → ~20-30% gain vs 6).
# ============================================================================

using Distributed
using EMSx
using Statistics

# ── 12 workers = 1 per logical thread (hyperthreading) ───────────────────────
const N_WORKERS = 12

if nprocs() < N_WORKERS + 1
    @info "Starting $N_WORKERS workers (1 per logical thread, hyperthreading)..."
    EMSx.init_parallel(N_WORKERS)
end
@info "Running with $(nworkers()) workers"

# ── Paths ─────────────────────────────────────────────────────────────────────
const DATA_DIR   = "/home/ebt/Downloads/emsx/dataset"
const RESULT_DIR = "/home/ebt/Downloads/emsx/results_sdp"
const EMSX_DIR   = "/home/ebt/Downloads/emsx/EMSx.jl"

const PRICE_PATH    = joinpath(EMSX_DIR, "metadata", "edf_prices.csv")
const METADATA_PATH = joinpath(DATA_DIR, "metadata.csv")
const TRAIN_PATH    = joinpath(DATA_DIR, "train")
const TEST_PATH     = joinpath(DATA_DIR, "test")

# ── Load modules on all workers ───────────────────────────────────────────────
@everywhere begin
    using EMSx
    using StoOpt
    using ControlVariables
    using JLD2
    using CSV, DataFrames, Dates
    using Clustering
    using ProgressMeter
    using Statistics

    include(joinpath($EMSX_DIR, "examples", "sdp", "function.jl"))
    include(joinpath($EMSX_DIR, "examples", "sdp", "calibrate.jl"))

    # ── Constants ──────────────────────────────────────────────────────────────
    const dx = 0.1       # SoC discretization
    const du = 0.1       # control discretization
    const horizon = 672  # 7 days × 96 steps/day
    const NZ = 20        # z grid points (net demand dimension)

    # ══════════════════════════════════════════════════════════════════════════
    # SDP-AR(1) Controller
    # ══════════════════════════════════════════════════════════════════════════
    mutable struct SdpAr1 <: EMSx.AbstractController
        model::Union{StoOpt.SDP, Nothing}
        value_functions::Union{StoOpt.ArrayValueFunctions, Nothing}
        alpha::Union{Array{Float64,1}, Nothing}   # AR(1) coefficient per time step (672)
        beta::Union{Array{Float64,1}, Nothing}     # AR(1) intercept per time step (672)
        z_min::Float64
        z_max::Float64
        SdpAr1() = new(nothing, nothing, nothing, nothing, 0.0, 0.0)
    end

    # ── Data preparation for AR(1) ────────────────────────────────────────────
    # Read training CSV → compute net demand → organize into (n_weeks, 672) matrix
    function net_demand_ar1_data(path_to_data_csv::String)
        data = EMSx.read_site_file(path_to_data_csv)
        net_demand = Float64.(data[!, :actual_consumption] .- data[!, :actual_pv])
        n = length(net_demand)
        n_weeks = n ÷ horizon
        if n_weeks < 2
            error("Not enough data for AR(1) model: $n time steps ($n_weeks weeks), need at least 2 weeks")
        end
        # Truncate to complete weeks
        net_demand = net_demand[1:n_weeks * horizon]
        # Reshape to (n_weeks, horizon): each row = one week of 672 consecutive steps
        # collect() converts Adjoint to Matrix{Float64} (required by fit_linear_noise_model)
        weeks_data = collect(reshape(net_demand, horizon, n_weeks)')
        return weeks_data
    end

    # ── Per-site controller initialization ─────────────────────────────────────
    function EMSx.initialize_site_controller(controller::SdpAr1, site::EMSx.Site, prices::EMSx.Prices)
        controller = SdpAr1()

        # 1) Fit AR(1) model on net demand
        weeks_data = net_demand_ar1_data(site.path_to_train_data_csv)
        weights, noises = ControlVariables.fit_linear_noise_model(weeks_data, 10)

        alpha = weights[1, :]   # α_t for each t ∈ 1:672
        beta  = weights[2, :]   # β_t for each t ∈ 1:672

        # 2) Compute z grid range from training data
        #    Use min/max with 50% margin to accommodate AR(1) propagation
        z_values = vec(weeks_data)
        z_lo, z_hi = extrema(z_values)
        z_range = z_hi - z_lo
        margin = 0.5 * max(z_range, 1e-3)  # 50% margin for AR(1) propagation
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

        # 5) Dynamics: (soc, z) → (soc', z')
        #    soc' = soc + (η_c·max(0,u) - max(0,-u)/η_d)·scale
        #    z'   = α_t·z + β_t + ε  (clipped to grid to avoid Inf cost-to-go)
        function offline_dynamics(t::Int64, state::Array{Float64,1},
                                  control::Array{Float64,1}, noise::Array{Float64,1})
            soc = state[1] + (_charge_eff * max(0., control[1]) -
                              max(0., -control[1]) / _discharge_eff) * _scale_factor
            z   = alpha[t] * state[2] + beta[t] + noise[1]
            z   = clamp(z, z_min, z_max)  # clip to grid bounds
            return [soc, z]
        end

        # 6) Cost: L_t(u, α_t·z + β_t + ε) — net demand is AR(1) prediction + residual
        #    The noise ε replaces the i.i.d. noise of plain SDP with the AR(1) residual,
        #    and the cost uses the full AR(1) prediction as the net demand.
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

    # ── Value function computation ─────────────────────────────────────────────
    function compute_value_functions(controller::SdpAr1)
        return StoOpt.compute_value_functions(controller.model)
    end

    # ── Load value functions from JLD2 ─────────────────────────────────────────
    function load_value_functions(site_id::String)
        return load(joinpath($RESULT_DIR, "sdp_ar1", "value_functions", site_id * ".jld2"))["value_function"]
    end

    # ── Online: compute control at each time step ──────────────────────────────
    #    z_t = information.load[1] - information.pv[1]  (most recent net demand)
    #    State = [soc, z_t], clipped to grid bounds
    function EMSx.compute_control(controller::SdpAr1, information::EMSx.Information)
        if information.t == 1
            controller.value_functions = load_value_functions(information.site_id)
        end
        # Compute current net demand from most recent observation
        z_t = information.load[1] - information.pv[1]
        # Clip z_t to grid range to avoid extrapolation issues
        z_t = clamp(z_t, controller.z_min, controller.z_max)
        # Extended state: [soc, z_t]
        control = StoOpt.compute_control(
            controller.model, information.t,
            [information.soc, z_t],
            StoOpt.RandomVariable(controller.model.noises, information.t),
            controller.value_functions
        )
        return control[1]
    end
end  # @everywhere

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Parallel Calibration
# ══════════════════════════════════════════════════════════════════════════════
function calibrate_sites_parallel(path_to_save_folder, path_to_price_csv,
                                  path_to_metadata_csv, path_to_train_data)
    @info "Phase 1/3: SDP-AR(1) calibration — $(nworkers()) workers, batch_size=1"

    mkpath(joinpath(path_to_save_folder, "value_functions"))
    prices = EMSx.load_prices(path_to_price_csv)
    sites = EMSx.load_sites(path_to_metadata_csv, nothing,
                            path_to_train_data, path_to_save_folder)

    n_sites = length(sites)
    @info "$n_sites sites to calibrate"

    elapsed = @elapsed begin
        results = @showprogress "  Calibrating: " pmap(1:n_sites, batch_size=1) do i
            site = sites[i]
            ctrl = EMSx.initialize_site_controller(SdpAr1(), site, prices)
            timer = @elapsed vf = compute_value_functions(ctrl)
            JLD2.save(joinpath(path_to_save_folder, "value_functions", site.id * ".jld2"),
                      Dict("value_function" => vf, "time" => timer,
                           "alpha" => ctrl.alpha, "beta" => ctrl.beta,
                           "z_min" => ctrl.z_min, "z_max" => ctrl.z_max))
            return timer
        end
    end

    @info "Calibration done: $(round(elapsed, digits=1))s total, " *
          "$(round(mean(results), digits=1))s/site avg, " *
          "min=$(round(minimum(results), digits=1))s max=$(round(maximum(results), digits=1))s"
    return nothing
end

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: Parallel Simulation
# ══════════════════════════════════════════════════════════════════════════════
function simulate_sites_parallel(controller, path_to_save_folder, path_to_price_csv,
                                 path_to_metadata_csv, path_to_test_data,
                                 path_to_train_data)
    @info "Phase 2/3: Simulation — $(nworkers()) workers, work-stealing"

    EMSx.simulate_sites_parallel(controller, path_to_save_folder,
                                  path_to_price_csv, path_to_metadata_csv,
                                  path_to_test_data, path_to_train_data)
    @info "Simulation complete."
    return nothing
end

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Evaluation
# ══════════════════════════════════════════════════════════════════════════════
function evaluate_results(path_to_save_folder)
    @info "Phase 3/3: Evaluation..."

    score_file = joinpath(path_to_save_folder, "score.jld2")

    if isfile(score_file)
        metrics = EMSx.evaluate_model(score_file)
        println("\n" * "="^60)
        println("  SDP-AR(1) Results")
        println("="^60)
        show(stdout, "text/plain", describe(metrics))
        println("\n")
        println("  Mean Score: $(round(mean(metrics.score), digits=4))")
        println("  Mean Gain:  $(round(mean(metrics.gain), digits=2))")
        println("  Mean Cost:  $(round(mean(metrics.cost), digits=2))")
        println("="^60)
        return metrics
    else
        @error "Score file not found at: $score_file"
        return nothing
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
function main()
    println("╔══════════════════════════════════════════════════════════╗")
    println("║   EMSx SDP-AR(1) — 12-Worker Parallel (Hyperthreading) ║")
    println("║   Workers: $(lpad(N_WORKERS, 2))   Sites: 70   Horizon: 672 steps     ║")
    println("╚══════════════════════════════════════════════════════════╝")
    println()

    total_time = @elapsed begin
        calibrate_sites_parallel(joinpath(RESULT_DIR, "sdp_ar1"),
                                 PRICE_PATH, METADATA_PATH, TRAIN_PATH)

        controller = SdpAr1()
        simulate_sites_parallel(controller, joinpath(RESULT_DIR, "sdp_ar1"),
                                PRICE_PATH, METADATA_PATH, TEST_PATH, TRAIN_PATH)

        evaluate_results(joinpath(RESULT_DIR, "sdp_ar1"))
    end

    println("\n  Total wall time: $(round(total_time/60, digits=1)) minutes")
end

main()
