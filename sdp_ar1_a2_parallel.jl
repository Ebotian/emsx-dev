#!/usr/bin/env julia
# ============================================================================
# EMSx SDP-AR(1) — A₂: Periodic Average-Cost SDP
# ============================================================================
# Usage: julia sdp_ar1_a2_parallel.jl
#
# Change vs A₁ (sdp_ar1_a1_parallel.jl):
#   Replace finite-horizon SDP (V_{672+1}=0) with periodic average-cost SDP
#   via iterative value iteration:
#     1. Round 1: standard backward DP with V_{672+1}=0 → V⁽¹⁾
#     2. Round 2: set final_cost = interpolated V⁽¹⁾[1], re-run backward DP → V⁽²⁾
#     3. Repeat until ‖V⁽ⁿ⁾[1] - V⁽ⁿ⁻¹⁾[1]‖ < tol
#   This eliminates two biases:
#     - Terminal effect: V_{672+1}=0 undervalues battery at end of week
#     - SOC reset: controller sees each week as independent, not continuous
#
# Inherits A₁'s deterministic 1D DP quantization.
#
# Hardware: Ryzen 5 9600X (6C/12T, 32GB RAM)
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
    using ProgressMeter
    using Statistics
    using LinearAlgebra
    using Interpolations: linear_interpolation, Line

    include(joinpath($EMSX_DIR, "examples", "sdp", "function.jl"))
    include(joinpath($EMSX_DIR, "examples", "sdp", "calibrate.jl"))

    # ── Constants ──────────────────────────────────────────────────────────────
    const dx = 0.1       # SoC discretization
    const du = 0.1       # control discretization
    const horizon = 672  # 7 days × 96 steps/day
    const NZ = 20        # z grid points (net demand dimension)
    const K_NOISE = 10   # number of noise levels
    const MAX_VI_ITERS = 3     # max value iteration rounds (shape converges in 2)
    const VI_TOL = 1e-3        # convergence tolerance on shape (de-meaned V₁)

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

    function fit_linear_noise_model_deterministic(data::Array{Float64,2}, k::Int64=K_NOISE)
        n_data, horizon_len = size(data)
        weights = zeros(2, horizon_len)
        support = zeros(k, horizon_len)
        probability = zeros(k, horizon_len)
        for t in 1:horizon_len
            if t == 1
                x = data[:, horizon_len]
                y = data[:, t]
            else
                x = data[:, t-1]
                y = data[:, t]
            end
            x = hcat(x, ones(size(x)))
            weights[:, t] = pinv(x'*x)*x'*y
            epsilon = vec(y - x*weights[:, t])
            supp, prob = deterministic_quantize_1d(epsilon, k)
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
        return weights, Noises(support, probability)
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
        SdpAr1A2() = new(nothing, nothing, nothing, nothing, 0.0, 0.0)
    end

    # ── Data preparation for AR(1) ────────────────────────────────────────────
    function net_demand_ar1_data(path_to_data_csv::String)
        data = EMSx.read_site_file(path_to_data_csv)
        net_demand = Float64.(data[!, :actual_consumption] .- data[!, :actual_pv])
        n = length(net_demand)
        n_weeks = n ÷ horizon
        if n_weeks < 2
            error("Not enough data for AR(1) model: $n time steps ($n_weeks weeks), need at least 2 weeks")
        end
        net_demand = net_demand[1:n_weeks * horizon]
        weeks_data = collect(reshape(net_demand, horizon, n_weeks)')
        return weeks_data
    end

    # ── Per-site controller initialization ─────────────────────────────────────
    function EMSx.initialize_site_controller(controller::SdpAr1A2, site::EMSx.Site, prices::EMSx.Prices)
        controller = SdpAr1A2()

        # 1) Fit AR(1) model with deterministic quantization (from A₁)
        weeks_data = net_demand_ar1_data(site.path_to_train_data_csv)
        weights, noises = fit_linear_noise_model_deterministic(weeks_data, K_NOISE)

        alpha = weights[1, :]
        beta  = weights[2, :]

        # 2) Compute z grid range
        z_values = vec(weeks_data)
        z_lo, z_hi = extrema(z_values)
        z_range = z_hi - z_lo
        margin = 0.5 * max(z_range, 1e-3)
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

    # ── Load value functions from JLD2 ─────────────────────────────────────────
    function load_value_functions(site_id::String, result_dir::String)
        return load(joinpath(result_dir, "value_functions", site_id * ".jld2"))["value_function"]
    end

    # ── Online: compute control at each time step ──────────────────────────────
    function EMSx.compute_control(controller::SdpAr1A2, information::EMSx.Information)
        if information.t == 1
            controller.value_functions = load_value_functions(
                information.site_id, joinpath($RESULT_DIR, "sdp_ar1_a2"))
        end
        z_t = information.load[1] - information.pv[1]
        z_t = clamp(z_t, controller.z_min, controller.z_max)
        control = StoOpt.compute_control(
            controller.model, information.t,
            [information.soc, z_t],
            StoOpt.RandomVariable(controller.model.noises, information.t),
            controller.value_functions
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

        # Continuous SOC: carries across periods (was 0.0 each period in stock)
        state_of_charge = 0.0

        for period_id in periods
            test_data_period = test_data[test_data.period_id .== period_id, :]
            period = EMSx.Period(string(period_id), test_data_period, site)
            h = size(period.data, 1) - 96
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

        EMSx.save_simulations(site, simulations)
        return nothing
    end
end  # @everywhere

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Parallel Calibration
# ══════════════════════════════════════════════════════════════════════════════
function calibrate_sites_parallel(path_to_save_folder, path_to_price_csv,
                                  path_to_metadata_csv, path_to_train_data)
    @info "Phase 1/3: SDP-AR(1) A₂ calibration — $(nworkers()) workers, batch_size=1"

    mkpath(joinpath(path_to_save_folder, "value_functions"))
    prices = EMSx.load_prices(path_to_price_csv)
    sites = EMSx.load_sites(path_to_metadata_csv, nothing,
                            path_to_train_data, path_to_save_folder)

    n_sites = length(sites)
    @info "$n_sites sites to calibrate (A₂: periodic VI, max $MAX_VI_ITERS iters)"

    elapsed = @elapsed begin
        results = @showprogress "  Calibrating (A₂ periodic VI): " pmap(1:n_sites, batch_size=1) do i
            site = sites[i]
            ctrl = EMSx.initialize_site_controller(SdpAr1A2(), site, prices)
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
# Phase 2: Parallel Simulation (continuous SOC across periods)
# ══════════════════════════════════════════════════════════════════════════════
function simulate_sites_parallel(controller, path_to_save_folder, path_to_price_csv,
                                 path_to_metadata_csv, path_to_test_data,
                                 path_to_train_data)
    @info "Phase 2/3: Simulation (continuous SOC) — $(nworkers()) workers, work-stealing"

    mkpath(path_to_save_folder)
    prices = EMSx.load_prices(path_to_price_csv)
    sites = EMSx.load_sites(path_to_metadata_csv, path_to_test_data,
                           path_to_train_data, path_to_save_folder)

    to_do = length(sites)

    @sync begin
        for p in workers()
            @async begin
                while true
                    idx = to_do
                    to_do -= 1
                    if idx <= 0
                        break
                    end
                    println("processing a new job - jobs left in queue : $(idx-1) / $(length(sites))")
                    _ = remotecall_fetch(simulate_site_continuous, p, controller, sites[idx], prices)
                end
            end
        end
    end

    EMSx.group_all_simulations(sites)
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
        println("  SDP-AR(1) A₂ (Periodic Average-Cost SDP) Results")
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
    println("║  EMSx SDP-AR(1) A₂ — Periodic Average-Cost SDP          ║")
    println("║  Workers: $(lpad(N_WORKERS, 2))   Sites: 70   VI iters: ≤$MAX_VI_ITERS       ║")
    println("╚══════════════════════════════════════════════════════════╝")
    println()

    result_subdir = joinpath(RESULT_DIR, "sdp_ar1_a2")

    total_time = @elapsed begin
        calibrate_sites_parallel(result_subdir,
                                 PRICE_PATH, METADATA_PATH, TRAIN_PATH)

        controller = SdpAr1A2()
        simulate_sites_parallel(controller, result_subdir,
                                PRICE_PATH, METADATA_PATH, TEST_PATH, TRAIN_PATH)

        evaluate_results(result_subdir)
    end

    println("\n  Total wall time: $(round(total_time/60, digits=1)) minutes")
end

main()
