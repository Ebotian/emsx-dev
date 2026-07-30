#!/usr/bin/env julia
# ============================================================================
# EMSx SDP-AR(1) — Parameter Sweep (A₁+A₂ base + hyperparameter variations)
# ============================================================================
# Runs multiple SDP-AR(1) configurations in parallel to find the best
# hyperparameters for reaching paper's 0.794 score.
#
# Base: A₁ deterministic quantization + A₂ periodic VI + continuous SOC
# Variants:
#   V1: dx=0.1, du=0.1, K=10, margin=0.50, NZ=20  (baseline = A₂)
#   V2: dx=0.05, du=0.1, K=10, margin=0.50, NZ=20 (finer SoC grid)
#   V3: dx=0.1, du=0.05, K=10, margin=0.50, NZ=20 (finer control)
#   V4: dx=0.1, du=0.1, K=20, margin=0.50, NZ=20  (more noise levels)
#   V5: dx=0.1, du=0.1, K=10, margin=0.25, NZ=20  (tighter z range)
#   V6: dx=0.1, du=0.1, K=10, margin=0.50, NZ=30  (finer z grid)
# ============================================================================

using Distributed
using EMSx
using Statistics

# ── 12 workers ────────────────────────────────────────────────────────────────
const N_WORKERS = 12

if nprocs() < N_WORKERS + 1
    @info "Starting $N_WORKERS workers..."
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

# ── Variants to test ──────────────────────────────────────────────────────────
struct Variant
    name::String
    dx::Float64
    du::Float64
    K::Int64
    margin::Float64
    NZ::Int64
end

const VARIANTS = [
    Variant("v1_baseline", 0.1,  0.1,  10, 0.50, 20),
    Variant("v2_fine_soc", 0.05, 0.1,  10, 0.50, 20),
    Variant("v3_fine_ctl", 0.1,  0.05, 10, 0.50, 20),
    Variant("v4_k20",      0.1,  0.1,  20, 0.50, 20),
    Variant("v5_margin25", 0.1,  0.1,  10, 0.25, 20),
    Variant("v6_nz30",     0.1,  0.1,  10, 0.50, 30),
]

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

    const horizon = 672
    const MAX_VI_ITERS = 3
    const VI_TOL = 1e-3

    # ── Deterministic 1D DP quantization (from A₁) ─────────────────────────────
    function interval_sse(ps::Vector{Float64}, psq::Vector{Float64}, a::Int64, b::Int64)
        n = b - a + 1
        s = ps[b] - (a > 1 ? ps[a-1] : 0.0)
        sq = psq[b] - (a > 1 ? psq[a-1] : 0.0)
        return sq - s * s / n
    end

    function deterministic_quantize_1d(epsilon::Vector{Float64}, K::Int64)
        n = length(epsilon)
        K = min(K, n)
        sorted_eps = sort(epsilon)
        ps = zeros(Float64, n)
        psq = zeros(Float64, n)
        ps[1] = sorted_eps[1]; psq[1] = sorted_eps[1]^2
        for i in 2:n
            ps[i] = ps[i-1] + sorted_eps[i]
            psq[i] = psq[i-1] + sorted_eps[i]^2
        end
        INF = Float64(1e18)
        D = fill(INF, K, n)
        back = zeros(Int64, K, n)
        for j in 1:n; D[1,j] = interval_sse(ps, psq, 1, j); end
        for k in 2:K
            for j in k:n
                best_c = INF; best_m = k-1
                for m in (k-1):(j-1)
                    c = D[k-1,m] + interval_sse(ps, psq, m+1, j)
                    if c < best_c; best_c = c; best_m = m; end
                end
                D[k,j] = best_c; back[k,j] = best_m
            end
        end
        levels = Vector{Vector{Int64}}()
        j = n
        for k in K:-1:1
            m = back[k,j]; push!(levels, collect((m+1):j)); j = m
        end
        reverse!(levels)
        support = Float64[]; probability = Float64[]
        for indices in levels
            if isempty(indices); continue; end
            a = indices[1]; b = indices[end]
            s = ps[b] - (a > 1 ? ps[a-1] : 0.0)
            cnt = b - a + 1
            push!(support, s/cnt); push!(probability, cnt/n)
        end
        return support, probability
    end

    function fit_linear_noise_model_det(data::Array{Float64,2}, k::Int64)
        n_data, h = size(data)
        weights = zeros(2, h)
        support = zeros(k, h); probability = zeros(k, h)
        for t in 1:h
            x = t == 1 ? data[:, h] : data[:, t-1]
            y = data[:, t]
            x = hcat(x, ones(size(x)))
            weights[:, t] = pinv(x'*x)*x'*y
            epsilon = vec(y - x*weights[:, t])
            supp, prob = deterministic_quantize_1d(epsilon, k)
            for i in 1:k
                if i <= length(supp)
                    support[i, t] = supp[i]; probability[i, t] = prob[i]
                else
                    support[i, t] = supp[end]; probability[i, t] = 0.0
                end
            end
        end
        return weights, Noises(support, probability)
    end

    # ── Periodic VI (from A₂) ──────────────────────────────────────────────────
    function make_periodic_final_cost(sdp_model, vf_step1)
        itp = linear_interpolation((sdp_model.states.axis[1], sdp_model.states.axis[2]),
                                    vf_step1; extrapolation_bc=Line())
        return (state::Array{Float64,1}) -> itp(state[1], state[2])
    end

    function compute_periodic_vf(sdp_model)
        vf = StoOpt.compute_value_functions(sdp_model)
        prev_v1 = copy(vf[1])
        for iter in 1:MAX_VI_ITERS
            sdp_model.final_cost = make_periodic_final_cost(sdp_model, vf[1])
            vf = StoOpt.compute_value_functions(sdp_model)
            cur_v1 = vf[1]
            shape_diff = maximum(abs.((cur_v1 .- mean(cur_v1)) .- (prev_v1 .- mean(prev_v1))))
            if shape_diff < VI_TOL; break; end
            prev_v1 = copy(vf[1])
        end
        sdp_model.final_cost = nothing
        return vf
    end

    # ── Parametric controller ──────────────────────────────────────────────────
    mutable struct SdpAr1Sweep <: EMSx.AbstractController
        model::Union{StoOpt.SDP, Nothing}
        value_functions::Union{StoOpt.ArrayValueFunctions, Nothing}
        alpha::Union{Array{Float64,1}, Nothing}
        beta::Union{Array{Float64,1}, Nothing}
        z_min::Float64
        z_max::Float64
        result_dir::String
        SdpAr1Sweep() = new(nothing, nothing, nothing, nothing, 0.0, 0.0, "")
    end

    function net_demand_ar1_data(path_to_data_csv::String)
        data = EMSx.read_site_file(path_to_data_csv)
        net_demand = Float64.(data[!, :actual_consumption] .- data[!, :actual_pv])
        n = length(net_demand)
        n_weeks = n ÷ horizon
        if n_weeks < 2; error("Not enough data"); end
        net_demand = net_demand[1:n_weeks * horizon]
        return collect(reshape(net_demand, horizon, n_weeks)')
    end

    # ── Continuous SOC simulation (from A₂) ────────────────────────────────────
    function simulate_site_continuous(controller::EMSx.AbstractController,
                                        site::EMSx.Site, prices::EMSx.Prices)
        test_data, site = EMSx.load_site_data(site)
        controller = EMSx.initialize_site_controller(controller, site, prices)
        periods = unique(test_data[!, :period_id])
        simulations = EMSx.Simulation[]
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

# ── Run one variant (calibrate + simulate + evaluate) ─────────────────────────
function run_variant(v::Variant)
    result_dir = joinpath(RESULT_DIR, "sweep_$(v.name)")

    # Pass variant params to workers
    @everywhere begin
        const _dx = $v.dx
        const _du = $v.du
        const _K = $v.K
        const _margin = $v.margin
        const _NZ = $v.NZ
        const _result_dir = $result_dir
    end

    @everywhere begin
        function EMSx.initialize_site_controller(controller::SdpAr1Sweep, site::EMSx.Site, prices::EMSx.Prices)
            controller = SdpAr1Sweep()
            controller.result_dir = _result_dir

            weeks_data = net_demand_ar1_data(site.path_to_train_data_csv)
            weights, noises = fit_linear_noise_model_det(weeks_data, _K)
            alpha = weights[1, :]
            beta  = weights[2, :]

            z_values = vec(weeks_data)
            z_lo, z_hi = extrema(z_values)
            z_range = z_hi - z_lo
            m = _margin * max(z_range, 1e-3)
            z_min = z_lo - m
            z_max = z_hi + m

            controller.alpha = alpha
            controller.beta  = beta
            controller.z_min = z_min
            controller.z_max = z_max

            z_axis = range(z_min, z_max, length=_NZ)

            _ce = site.battery.charge_efficiency
            _de = site.battery.discharge_efficiency
            _pw = site.battery.power
            _cap = site.battery.capacity
            _sf = _pw * 0.25 / _cap
            _bp = prices.buy
            _sp = prices.sell

            function offline_dynamics(t, state, control, noise)
                soc = state[1] + (_ce * max(0., control[1]) - max(0., -control[1]) / _de) * _sf
                z = alpha[t] * state[2] + beta[t] + noise[1]
                return [clamp(soc, 0.0, 1.0), clamp(z, z_min, z_max)]
            end

            function offline_cost(t, state, control, noise)
                z_pred = alpha[t] * state[2] + beta[t] + noise[1]
                ckwh = control[1] * _pw * 0.25
                ie = ckwh + z_pred
                return (_bp[t] * max(0., ie) - _sp[t] * max(0., -ie))
            end

            model = StoOpt.SDP(
                States(horizon, 0.0:_dx:1.0, z_axis),
                Controls(horizon, -1.0:_du:1.0),
                noises, offline_cost, offline_dynamics, horizon
            )
            controller.model = model
            return controller
        end

        function compute_value_functions(controller::SdpAr1Sweep)
            return compute_periodic_vf(controller.model)
        end

        function EMSx.compute_control(controller::SdpAr1Sweep, information::EMSx.Information)
            if information.t == 1
                controller.value_functions = load(joinpath(controller.result_dir,
                    "value_functions", information.site_id * ".jld2"))["value_function"]
            end
            z_t = clamp(information.load[1] - information.pv[1], controller.z_min, controller.z_max)
            control = StoOpt.compute_control(controller.model, information.t,
                [information.soc, z_t],
                StoOpt.RandomVariable(controller.model.noises, information.t),
                controller.value_functions)
            return control[1]
        end
    end  # @everywhere

    # Phase 1: Calibrate
    @info "[$(v.name)] Phase 1/3: Calibration"
    mkpath(joinpath(result_dir, "value_functions"))
    prices = EMSx.load_prices(PRICE_PATH)
    sites = EMSx.load_sites(METADATA_PATH, nothing, TRAIN_PATH, result_dir)

    elapsed_cal = @elapsed begin
        cal_times = pmap(1:length(sites), batch_size=1) do i
            site = sites[i]
            ctrl = EMSx.initialize_site_controller(SdpAr1Sweep(), site, prices)
            timer = @elapsed vf = compute_value_functions(ctrl)
            JLD2.save(joinpath(result_dir, "value_functions", site.id * ".jld2"),
                      Dict("value_function" => vf, "time" => timer,
                           "alpha" => ctrl.alpha, "beta" => ctrl.beta,
                           "z_min" => ctrl.z_min, "z_max" => ctrl.z_max))
            return timer
        end
    end

    # Phase 2: Simulate
    @info "[$(v.name)] Phase 2/3: Simulation"
    sites2 = EMSx.load_sites(METADATA_PATH, TEST_PATH, TRAIN_PATH, result_dir)
    to_do = length(sites2)
    @sync begin
        for p in workers()
            @async begin
                while true
                    idx = to_do; to_do -= 1
                    if idx <= 0; break; end
                    _ = remotecall_fetch(simulate_site_continuous, p, SdpAr1Sweep(), sites2[idx], prices)
                end
            end
        end
    end
    EMSx.group_all_simulations(sites2)

    # Phase 3: Evaluate
    score_file = joinpath(result_dir, "score.jld2")
    if isfile(score_file)
        metrics = EMSx.evaluate_model(score_file)
        ms = mean(metrics.score)
        mg = mean(metrics.gain)
        @info "[$(v.name)] Score: $(round(ms, digits=4)), Gain: $(round(mg, digits=2)), Cal: $(round(elapsed_cal, digits=1))s"
        return (name=v.name, score=ms, gain=mg, cal_time=elapsed_cal,
                dx=v.dx, du=v.du, K=v.K, margin=v.margin, NZ=v.NZ)
    else
        @error "[$(v.name)] No score file"
        return (name=v.name, score=0.0, gain=0.0, cal_time=elapsed_cal,
                dx=v.dx, du=v.du, K=v.K, margin=v.margin, NZ=v.NZ)
    end
end

# ══════════════════════════════════════════════════════════════════════════════
# Main: Run all variants sequentially (each uses all 12 workers internally)
# ══════════════════════════════════════════════════════════════════════════════
function main()
    println("╔══════════════════════════════════════════════════════════╗")
    println("║  EMSx SDP-AR(1) — Parameter Sweep (6 variants)          ║")
    println("╚══════════════════════════════════════════════════════════╝")
    println()

    results = []
    for v in VARIANTS
        println("\n$(repeat("=", 60))")
        println("  Running $(v.name): dx=$(v.dx), du=$(v.du), K=$(v.K), margin=$(v.margin), NZ=$(v.NZ)")
        println("$(repeat("=", 60))")

        r = run_variant(v)
        push!(results, r)

        println("\n  [$(r.name)] Score: $(round(r.score, digits=4)), Gain: $(round(r.gain, digits=2))")
    end

    # Summary
    println("\n$(repeat("=", 70))")
    println("  PARAMETER SWEEP SUMMARY")
    println("$(repeat("=", 70))")
    println("  $(rpad("Variant", 15)) $(rpad("Score", 10)) $(rpad("Gain", 10)) $(rpad("dx", 8)) $(rpad("du", 8)) $(rpad("K", 5)) $(rpad("margin", 8)) $(rpad("NZ", 5))")
    println("  $(repeat("-", 70))")
    for r in sort(results, by=x->x.score, rev=true)
        println("  $(rpad(r.name, 15)) $(rpad(round(r.score, digits=4), 10)) $(rpad(round(r.gain, digits=2), 10)) $(rpad(r.dx, 8)) $(rpad(r.du, 8)) $(rpad(r.K, 5)) $(rpad(r.margin, 8)) $(rpad(r.NZ, 5))")
    end
    println("$(repeat("=", 70))")
end

main()
