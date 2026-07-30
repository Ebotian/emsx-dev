#!/usr/bin/env julia
# ============================================================================
# EMSx SDP-AR(1) — A₁: Deterministic 1D DP Quantization
# ============================================================================
# Usage: julia sdp_ar1_a1_parallel.jl
#
# Change vs A₀ (sdp_ar1_parallel.jl):
#   Replace k-means noise quantization with deterministic 1D DP optimal
#   quantizer (global optimum, no random seed, fully reproducible).
#   Everything else identical: same OLS AR(1) regression, same SDP horizon,
#   same cost/dynamics, same grid.
#
# Algorithm: SDP with AR(1) noise model on net demand (§5.2.2 of paper)
#   - Extended state: (soc, z_t) where z_t = most recent net demand
#   - AR(1) dynamics: z_{t+1} = α_t·z_t + β_t + ε_{t+1}
#   - Cost uses AR(1) prediction: net_demand = α_t·z_t + β_t + ε
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
    using LinearAlgebra  # pinv for OLS regression

    include(joinpath($EMSX_DIR, "examples", "sdp", "function.jl"))
    include(joinpath($EMSX_DIR, "examples", "sdp", "calibrate.jl"))

    # ── Constants ──────────────────────────────────────────────────────────────
    const dx = 0.1       # SoC discretization
    const du = 0.1       # control discretization
    const horizon = 672  # 7 days × 96 steps/day
    const NZ = 20        # z grid points (net demand dimension)
    const K_NOISE = 10   # number of noise levels (same as A₀)

    # ══════════════════════════════════════════════════════════════════════════
    # A₁: Deterministic 1D DP Optimal Quantization
    # ══════════════════════════════════════════════════════════════════════════
    # Given sorted residuals ε_(1) ≤ ... ≤ ε_(n), find K levels that minimize
    # total quantization SSE using dynamic programming:
    #   C(a,b) = min_c Σ_{j=a}^{b} (ε_(j) - c)²   (optimal c = mean of ε_(a:b))
    #   D(k,j) = min_{m<j} [ D(k-1,m) + C(m+1,j) ]
    # Returns: support (K values), probability (K weights), both sorted.
    # ───────────────────────────────────────────────────────────────────────────

    """
    Compute SSE of quantizing sorted data[a:b] to a single level (the mean).
    Uses prefix sums for O(1) computation:
      SSE = Σx² - n·mean² = Σx² - (Σx)²/n
    """
    function interval_sse(prefix_sum::Vector{Float64}, prefix_sqsum::Vector{Float64},
                          a::Int64, b::Int64)
        n = b - a + 1
        s = prefix_sum[b] - (a > 1 ? prefix_sum[a-1] : 0.0)
        sq = prefix_sqsum[b] - (a > 1 ? prefix_sqsum[a-1] : 0.0)
        return sq - s * s / n
    end

    """
    1D DP optimal quantization of a set of scalar values into K levels.
    Returns (support::Vector{Float64}, probability::Vector{Float64}) sorted by support.
    """
    function deterministic_quantize_1d(epsilon::Vector{Float64}, K::Int64)
        n = length(epsilon)
        K = min(K, n)  # can't have more levels than data points

        # Sort residuals
        sorted_eps = sort(epsilon)

        # Prefix sums for O(1) interval SSE
        prefix_sum = zeros(Float64, n)
        prefix_sqsum = zeros(Float64, n)
        prefix_sum[1] = sorted_eps[1]
        prefix_sqsum[1] = sorted_eps[1]^2
        for i in 2:n
            prefix_sum[i] = prefix_sum[i-1] + sorted_eps[i]
            prefix_sqsum[i] = prefix_sqsum[i-1] + sorted_eps[i]^2
        end

        # DP table: D[k, j] = min cost to quantize sorted_eps[1:j] into k levels
        # back[k, j] = optimal split point
        INF = Float64(1e18)
        D = fill(INF, K, n)
        back = zeros(Int64, K, n)

        # Base case: k=1, quantize sorted_eps[1:j] to single mean
        for j in 1:n
            D[1, j] = interval_sse(prefix_sum, prefix_sqsum, 1, j)
            back[1, j] = 0
        end

        # Fill DP for k=2..K
        for k in 2:K
            for j in k:n  # need at least k points for k levels
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

        # Backtrack to find level assignments
        levels = Vector{Vector{Int64}}()
        j = n
        for k in K:-1:1
            m = back[k, j]
            push!(levels, collect((m+1):j))
            j = m
        end
        reverse!(levels)

        # Compute support (mean of each level) and probability (count/n)
        support = Float64[]
        probability = Float64[]
        for (idx, indices) in enumerate(levels)
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

        # Already sorted because we process sorted data left-to-right
        return support, probability
    end

    """
    Deterministic AR(1) noise model: OLS regression (same as fit_linear_noise_model)
    but with 1D DP optimal quantization instead of k-means.
    Returns (weights, Noises) with identical interface to ControlVariables.fit_linear_noise_model.
    """
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

            # A₁: deterministic 1D DP quantization (replaces k-means)
            supp, prob = deterministic_quantize_1d(epsilon, k)

            # Pad if fewer than k levels (happens when n_data < k)
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
    # SDP-AR(1) Controller (A₁ variant)
    # ══════════════════════════════════════════════════════════════════════════
    mutable struct SdpAr1A1 <: EMSx.AbstractController
        model::Union{StoOpt.SDP, Nothing}
        value_functions::Union{StoOpt.ArrayValueFunctions, Nothing}
        alpha::Union{Array{Float64,1}, Nothing}
        beta::Union{Array{Float64,1}, Nothing}
        z_min::Float64
        z_max::Float64
        SdpAr1A1() = new(nothing, nothing, nothing, nothing, 0.0, 0.0)
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
    function EMSx.initialize_site_controller(controller::SdpAr1A1, site::EMSx.Site, prices::EMSx.Prices)
        controller = SdpAr1A1()

        # 1) Fit AR(1) model — A₁: deterministic quantization (not k-means)
        weeks_data = net_demand_ar1_data(site.path_to_train_data_csv)
        weights, noises = fit_linear_noise_model_deterministic(weeks_data, K_NOISE)

        alpha = weights[1, :]
        beta  = weights[2, :]

        # 2) Compute z grid range from training data
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

        # 5) Dynamics: (soc, z) → (soc', z')
        function offline_dynamics(t::Int64, state::Array{Float64,1},
                                  control::Array{Float64,1}, noise::Array{Float64,1})
            soc = state[1] + (_charge_eff * max(0., control[1]) -
                              max(0., -control[1]) / _discharge_eff) * _scale_factor
            z   = alpha[t] * state[2] + beta[t] + noise[1]
            z   = clamp(z, z_min, z_max)
            return [soc, z]
        end

        # 6) Cost: L_t(u, α_t·z + β_t + ε)
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
    function compute_value_functions(controller::SdpAr1A1)
        return StoOpt.compute_value_functions(controller.model)
    end

    # ── Load value functions from JLD2 ─────────────────────────────────────────
    function load_value_functions(site_id::String, result_dir::String)
        return load(joinpath(result_dir, "value_functions", site_id * ".jld2"))["value_function"]
    end

    # ── Online: compute control at each time step ──────────────────────────────
    function EMSx.compute_control(controller::SdpAr1A1, information::EMSx.Information)
        if information.t == 1
            controller.value_functions = load_value_functions(
                information.site_id, joinpath($RESULT_DIR, "sdp_ar1_a1"))
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
end  # @everywhere

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Parallel Calibration
# ══════════════════════════════════════════════════════════════════════════════
function calibrate_sites_parallel(path_to_save_folder, path_to_price_csv,
                                  path_to_metadata_csv, path_to_train_data)
    @info "Phase 1/3: SDP-AR(1) A₁ calibration — $(nworkers()) workers, batch_size=1"

    mkpath(joinpath(path_to_save_folder, "value_functions"))
    prices = EMSx.load_prices(path_to_price_csv)
    sites = EMSx.load_sites(path_to_metadata_csv, nothing,
                            path_to_train_data, path_to_save_folder)

    n_sites = length(sites)
    @info "$n_sites sites to calibrate"

    elapsed = @elapsed begin
        results = @showprogress "  Calibrating (A₁ deterministic quant): " pmap(1:n_sites, batch_size=1) do i
            site = sites[i]
            ctrl = EMSx.initialize_site_controller(SdpAr1A1(), site, prices)
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
        println("  SDP-AR(1) A₁ (Deterministic Quantization) Results")
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
    println("║  EMSx SDP-AR(1) A₁ — Deterministic DP Quantization     ║")
    println("║  Workers: $(lpad(N_WORKERS, 2))   Sites: 70   Horizon: 672 steps     ║")
    println("╚══════════════════════════════════════════════════════════╝")
    println()

    result_subdir = joinpath(RESULT_DIR, "sdp_ar1_a1")

    total_time = @elapsed begin
        calibrate_sites_parallel(result_subdir,
                                 PRICE_PATH, METADATA_PATH, TRAIN_PATH)

        controller = SdpAr1A1()
        simulate_sites_parallel(controller, result_subdir,
                                PRICE_PATH, METADATA_PATH, TEST_PATH, TRAIN_PATH)

        evaluate_results(result_subdir)
    end

    println("\n  Total wall time: $(round(total_time/60, digits=1)) minutes")
end

main()
