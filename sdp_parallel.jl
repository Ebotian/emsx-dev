#!/usr/bin/env julia
# ============================================================================
# EMSx SDP-AR(1) — 6-Core Parallel Benchmark
# ============================================================================
# Usage: julia sdp_parallel.jl
#
# Hardware: Ryzen 5 9600X (6 physical cores / 12 threads, 5.4GHz, 32GB RAM)
# Strategy:  6 workers = 1 per physical core. Hyperthreading doesn't help
#            CPU-bound Julia processes (no GIL sharing, cache thrashing).
#            Memory: 6 × ~350MB ≈ 2.1GB peak — well within 32GB.
#
# Phases:
#   1. Calibrate — pmap over 70 sites, batch_size=1 (work-stealing)
#   2. Simulate  — EMSx.simulate_sites_parallel (built-in work-stealing)
#   3. Evaluate  — EMSx.evaluate_model (score per site + aggregate)
# ============================================================================

using Distributed
using EMSx
using Statistics

# ── 6 workers = 1 per physical core ─────────────────────────────────────────
const N_WORKERS = 6

if nprocs() < N_WORKERS + 1
    @info "Starting $N_WORKERS workers (1 per physical core)..."
    EMSx.init_parallel(N_WORKERS)
end
@info "Running with $(nworkers()) workers"

# ── Paths ───────────────────────────────────────────────────────────────────
const DATA_DIR   = "/home/ebt/Downloads/emsx/dataset"
const RESULT_DIR = "/home/ebt/Downloads/emsx/results_sdp"
const EMSX_DIR   = "/home/ebt/Downloads/emsx/EMSx.jl"

const PRICE_PATH    = joinpath(EMSX_DIR, "metadata", "edf_prices.csv")
const METADATA_PATH = joinpath(DATA_DIR, "metadata.csv")
const TRAIN_PATH    = joinpath(DATA_DIR, "train")
const TEST_PATH     = joinpath(DATA_DIR, "test")

# ── Load modules on all workers ─────────────────────────────────────────────
@everywhere begin
    using EMSx
    using StoOpt
    using ControlVariables
    using JLD2
    using CSV, DataFrames, Dates
    using Clustering
    using ProgressMeter

    include(joinpath($EMSX_DIR, "examples", "sdp", "function.jl"))
    include(joinpath($EMSX_DIR, "examples", "sdp", "calibrate.jl"))

    # ── SDP Controller definition ────────────────────────────────────────────
    mutable struct Sdp <: EMSx.AbstractController
        model::StoOpt.SDP
        value_functions::Union{StoOpt.ArrayValueFunctions, Nothing}
        Sdp() = new()
    end

    const dx = 0.1       # SoC discretization
    const du = 0.1       # control discretization
    const horizon = 672   # 7 days × 96 steps/day

    # ── Per-site controller initialization ───────────────────────────────────
    function EMSx.initialize_site_controller(controller::Sdp, site::EMSx.Site, prices::EMSx.Prices)
        controller = Sdp()

        offline_law_data_frames = net_demand_offline_law(site.path_to_train_data_csv)
        noises = data_frames_to_noises(offline_law_data_frames)

        function offline_dynamics(t::Int64, state::Array{Float64,1}, control::Array{Float64,1},
                                  noise::Array{Float64,1})
            scale_factor = site.battery.power * 0.25 / site.battery.capacity
            soc = state + (site.battery.charge_efficiency * max.(0., control) -
                           max.(0., -control) / site.battery.discharge_efficiency) * scale_factor
            return soc
        end

        function offline_cost(t::Int64, state::Array{Float64,1}, control::Array{Float64,1},
                              noise::Array{Float64,1})
            control = control[1] * site.battery.power * 0.25
            imported_energy = control + noise[1]
            return (prices.buy[t] * max(0., imported_energy) -
                    prices.sell[t] * max(0., -imported_energy))
        end

        model = StoOpt.SDP(States(horizon, 0:dx:1),
                           Controls(horizon, -1:du:1),
                           noises,
                           offline_cost,
                           offline_dynamics,
                           horizon)
        controller.model = model
        return controller
    end

    function compute_value_functions(controller::Sdp)
        return StoOpt.compute_value_functions(controller.model)
    end

    function load_value_functions(site_id::String)
        return load(joinpath($RESULT_DIR, "sdp", "value_functions", site_id * ".jld2"))["value_function"]
    end

    function EMSx.compute_control(controller::Sdp, information::EMSx.Information)
        if information.t == 1
            controller.value_functions = load_value_functions(information.site_id)
        end
        control = StoOpt.compute_control(controller.model, information.t, [information.soc],
            StoOpt.RandomVariable(controller.model.noises, information.t),
            controller.value_functions)
        return control[1]
    end
end  # @everywhere

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Parallel Calibration
# ══════════════════════════════════════════════════════════════════════════════
function calibrate_sites_parallel(path_to_save_folder, path_to_price_csv,
                                  path_to_metadata_csv, path_to_train_data)
    @info "Phase 1/3: SDP calibration — $(nworkers()) workers, batch_size=1"

    mkpath(joinpath(path_to_save_folder, "value_functions"))
    prices = EMSx.load_prices(path_to_price_csv)
    sites = EMSx.load_sites(path_to_metadata_csv, nothing,
                            path_to_train_data, path_to_save_folder)

    n_sites = length(sites)
    @info "$n_sites sites to calibrate"

    # batch_size=1: each site dispatched individually to next free worker
    # → better load balancing when sites vary in size
    elapsed = @elapsed begin
        results = @showprogress "  Calibrating: " pmap(1:n_sites, batch_size=1) do i
            site = sites[i]
            ctrl = EMSx.initialize_site_controller(Sdp(), site, prices)
            timer = @elapsed vf = compute_value_functions(ctrl)
            JLD2.save(joinpath(path_to_save_folder, "value_functions", site.id * ".jld2"),
                      Dict("value_function" => vf, "time" => timer))
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
    if !isfile(score_file)
        score_file = joinpath(path_to_save_folder, "sdp", "score.jld2")
    end

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
    println("║   EMSx SDP-AR(1) — 6-Core Parallel Benchmark           ║")
    println("║   Workers: $(lpad(N_WORKERS, 2))   Sites: 70   Horizon: 672 steps     ║")
    println("╚══════════════════════════════════════════════════════════╝")
    println()

    total_time = @elapsed begin
        calibrate_sites_parallel(joinpath(RESULT_DIR, "sdp"),
                                 PRICE_PATH, METADATA_PATH, TRAIN_PATH)

        controller = Sdp()
        simulate_sites_parallel(controller, joinpath(RESULT_DIR, "sdp"),
                                PRICE_PATH, METADATA_PATH, TEST_PATH, TRAIN_PATH)

        evaluate_results(joinpath(RESULT_DIR, "sdp"))
    end

    println("\n  Total wall time: $(round(total_time/60, digits=1)) minutes")
end

main()
