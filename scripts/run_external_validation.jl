#!/usr/bin/env julia
# ============================================================================
# External dataset validation: S_AR (SDP-AR(1)) vs R_P (persistence) vs Dummy
# Works on any dataset prepared as:
#   <dataset_dir>/<site>/{train.csv, test.csv, battery.json}
#     train/test.csv columns: timestamp,z,price_buy,price_sell  (z = net demand kW)
#     battery.json: {power_kw, capacity_kwh, charge_eff, discharge_eff}
# Usage:
#   julia run_external_validation.jl <dataset_dir> <n_slots_per_day> [site_ids...]
#   n_slots_per_day: 48 (30min) or 288 (5min); horizon = 7 * n_slots
# Output per site: <dataset_dir>/results/<site>.json
#   {cost: {sdp, rp, dummy}, gain: {sdp, rp}, score..., curves: {actual, ar1, persist}}
# ============================================================================
using StoOpt
using ControlVariables
using CSV, DataFrames, Statistics, JSON, LinearAlgebra
using Interpolations
using Dates

const DATASET_DIR = ARGS[1]
const N_SLOTS = parse(Int, ARGS[2])
const HORIZON = 7 * N_SLOTS
const K_NOISE = 20
const NZ = 20
const DX = 0.1
const DU = 0.1
const MAX_VI_ITERS = 30
const VI_TOL = 1e-3
const MARGIN = 0.5
const CURVE_WINDOW = 2 * N_SLOTS  # 2 days for dispatch-forecast curves

SITE_IDS = isempty(ARGS[3:end]) ? sort(readdir(DATASET_DIR)) : ARGS[3:end]
SITE_IDS = filter(s -> isdir(joinpath(DATASET_DIR, s)) && s != "results", SITE_IDS)

mkpath(joinpath(DATASET_DIR, "results"))

# ---------------------------------------------------------------------------
# Real-time-of-week slot index: timestamps -> 1..HORIZON (Mon 00:00 = 1),
# aligned to the actual calendar so the per-slot tariff/AR(1) pattern is
# evaluated at the correct day-of-week and time-of-day for BOTH train and
# test (position-based indexing silently misaligns when test starts on a
# different weekday than train).
# ---------------------------------------------------------------------------
function week_slot(ts::AbstractString, n_slots::Int)
    dt = DateTime(ts[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
    slot_of_day = round(Int, (Dates.hour(dt) * 60 + Dates.minute(dt)) / (60 * 24) * n_slots) + 1
    return (Dates.dayofweek(dt) - 1) * n_slots + slot_of_day
end
week_slot(ts::Date, n_slots::Int) = week_slot(string(ts), n_slots)

# ---------------------------------------------------------------------------
# Deterministic 1D DP optimal quantization (same as wdwe2 A1)
# ---------------------------------------------------------------------------
function interval_sse(ps::Vector{Float64}, pss::Vector{Float64}, a::Int, b::Int)
    n = b - a + 1
    s = ps[b] - (a > 1 ? ps[a-1] : 0.0)
    sq = pss[b] - (a > 1 ? pss[a-1] : 0.0)
    return sq - s * s / n
end

function deterministic_quantize_1d(epsilon::Vector{Float64}, K::Int)
    n = length(epsilon)
    K = min(K, n)
    s = sort(epsilon)
    ps = zeros(Float64, n); pss = zeros(Float64, n)
    ps[1] = s[1]; pss[1] = s[1]^2
    for i in 2:n
        ps[i] = ps[i-1] + s[i]
        pss[i] = pss[i-1] + s[i]^2
    end
    INF = 1e18
    D = fill(INF, K, n); back = zeros(Int, K, n)
    for j in 1:n
        D[1, j] = interval_sse(ps, pss, 1, j)
    end
    for k in 2:K, j in k:n
        best = INF; best_m = k - 1
        for m in (k-1):(j-1)
            c = D[k-1, m] + interval_sse(ps, pss, m+1, j)
            if c < best
                best = c; best_m = m
            end
        end
        D[k, j] = best; back[k, j] = best_m
    end
    j = n; levels = Vector{Vector{Int}}()
    for k in K:-1:1
        m = back[k, j]
        push!(levels, collect((m+1):j))
        j = m
    end
    reverse!(levels)
    support = Float64[]; prob = Float64[]
    for idx in levels
        isempty(idx) && continue
        a = idx[1]; b = idx[end]
        s = ps[b] - (a > 1 ? ps[a-1] : 0.0)
        push!(support, s / (b - a + 1))
        push!(prob, (b - a + 1) / n)
    end
    return support, prob
end

# ---------------------------------------------------------------------------
# AR(1) fit: weekday/weekend × n_slots grouped OLS + deterministic quantization
# Returns alpha, beta (length HORIZON), noise support/prob (k × HORIZON)
# ---------------------------------------------------------------------------
function fit_ar1(train_df::DataFrame)
    z = Float64.(train_df.z)
    n = length(z)
    n < HORIZON && error("need >= HORIZON training samples")
    tau = [week_slot(string(ts), N_SLOTS) for ts in train_df.timestamp]
    alpha = zeros(HORIZON); beta = zeros(HORIZON)
    support = zeros(K_NOISE, HORIZON); probability = zeros(K_NOISE, HORIZON)
    # collect all consecutive pairs (z[i-1] -> z[i]); each pair belongs to the
    # real-time-of-week slot of its target index i. Uses ALL training days (not
    # just whole weeks) so short datasets (e.g. 14-day AEMO) get max samples.
    for t in 1:HORIZON
        q = ((t - 1) % N_SLOTS) + 1
        we = ((t - 1) ÷ N_SLOTS) + 1 >= 6
        xs = Float64[]; ys = Float64[]
        for i in 2:n
            τi = tau[i]
            iq = ((τi - 1) % N_SLOTS) + 1
            iwe = ((τi - 1) ÷ N_SLOTS) + 1 >= 6
            if iq == q && iwe == we
                push!(xs, z[i-1]); push!(ys, z[i])
            end
        end
        length(xs) >= 2 || continue
        X = hcat(xs, ones(length(xs)))
        w_reg = pinv(X' * X) * X' * ys
        alpha[t] = w_reg[1]; beta[t] = w_reg[2]
        eps = ys - X * w_reg
        supp, pr = deterministic_quantize_1d(eps, K_NOISE)
        for i in 1:K_NOISE
            if i <= length(supp)
                support[i, t] = supp[i]; probability[i, t] = pr[i]
            else
                support[i, t] = supp[end]; probability[i, t] = 0.0
            end
        end
    end
    # fallback: any slot whose group was skipped (too few samples) gets a
    # deterministic zero-noise kernel so every transition row sums to 1.
    for t in 1:HORIZON
        if sum(probability[:, t]) == 0.0
            probability[1, t] = 1.0
            support[1, t] = 0.0
            for i in 2:K_NOISE
                support[i, t] = 0.0
            end
        end
    end
    return alpha, beta, support, probability
end

# ---------------------------------------------------------------------------
# SDP build + periodic average-cost VI (wdwe2 A2 pattern)
# ---------------------------------------------------------------------------
function make_periodic_final_cost(sdp_model, vf_step1)
    soc_axis = sdp_model.states.axis[1]
    z_axis = sdp_model.states.axis[2]
    itp = Interpolations.linear_interpolation((soc_axis, z_axis), vf_step1; extrapolation_bc=Interpolations.Line())
    return (state::Vector{Float64}) -> itp(state[1], state[2])
end

function compute_periodic_value_functions(sdp_model; max_iters=MAX_VI_ITERS, tol=VI_TOL)
    vf = StoOpt.compute_value_functions(sdp_model)
    prev_v1 = copy(vf[1])
    for _ in 1:max_iters
        final_cost_fn = make_periodic_final_cost(sdp_model, vf[1])
        sdp_model.final_cost = final_cost_fn
        vf = StoOpt.compute_value_functions(sdp_model)
        cur_v1 = vf[1]
        cur_mean = mean(cur_v1); prev_mean = mean(prev_v1)
        shape_diff = maximum(abs.((cur_v1 .- cur_mean) .- (prev_v1 .- prev_mean)))
        shape_diff < tol && break
        prev_v1 = copy(vf[1])
    end
    sdp_model.final_cost = nothing
    return vf
end

# ---------------------------------------------------------------------------
# Generic replay with time step dt (hours). All controllers use the value
# function with a one-step forecast; they differ only in the forecast:
#   :dummy       u = 0
#   :rp          z_next = z_t           (persistence)
#   :sdp         z_next = alpha*z_t+beta (AR(1))
# ---------------------------------------------------------------------------
function replay(model, vf, alpha, beta, z_min, z_max, test_df, battery, ctrl, buy_slot, sell_slot)
    power = battery["power_kw"]; capacity = battery["capacity_kwh"]
    eta_c = battery["charge_eff"]; eta_d = battery["discharge_eff"]
    dt = 15.0 / 60.0 * (96 / N_SLOTS)  # step hours
    z = Float64.(test_df.z)
    buy = Float64.(test_df.price_buy)
    sell = Float64.(test_df.price_sell)
    tau_te = [week_slot(string(ts), N_SLOTS) for ts in test_df.timestamp]
    n = length(z)
    soc = 0.0
    cost_total = 0.0
    vf_arr = vf.functions
    soc_axis = model.states.axis[1]
    z_axis = model.states.axis[2]
    u_seq = zeros(n); soc_seq = zeros(n); cost_seq = zeros(n)
    # pre-build interpolators once per horizon slot (per-step construction is slow)
    itps = [linear_interpolation((soc_axis, z_axis), vf_arr[τ + 1, :, :]; extrapolation_bc=Line()) for τ in 1:HORIZON]
    for t in 1:n
        τ = tau_te[t]
        z_t = clamp(z[t], z_min, z_max)
        if ctrl === :dummy
            u = 0.0
        else
            z_next = ctrl === :sdp ? alpha[τ] * z_t + beta[τ] : z_t
            z_next = clamp(z_next, z_min, z_max)
            itp = itps[τ]
            # physical action bounds: keep next SOC in [0,1] (no free energy)
            lo = max(-soc * eta_d * capacity / (power * dt), -1.0)
            hi = min((1.0 - soc) * capacity / (eta_c * power * dt), 1.0)
            best = Inf; u = 0.0
            # decision uses per-slot average prices (consistent with the value
            # function); the replayed cost below uses actual prices.
            for uc in -1.0:DU:1.0
                uc < lo && continue
                uc > hi && continue
                soc_n = soc + (eta_c * max(0.0, uc) - max(0.0, -uc) / eta_d) * power * dt / capacity
                import_kwh = z_t + uc * power * dt
                c = buy_slot[τ] * max(0.0, import_kwh) - sell_slot[τ] * max(0.0, -import_kwh) + itp(soc_n, z_next)
                if c < best
                    best = c; u = uc
                end
            end
        end
        # physical action filter on application too
        u = clamp(u, max(-soc * eta_d * capacity / (power * dt), -1.0),
                     min((1.0 - soc) * capacity / (eta_c * power * dt), 1.0))
        soc_new = soc + (eta_c * max(0.0, u) - max(0.0, -u) / eta_d) * power * dt / capacity
        import_kwh = z_t + u * power * dt
        # replayed cost uses the per-slot tariff (train-mean prices), the same
        # schedule the controller was optimized against — structurally parallel
        # to Ausgrid's fixed TOU tariff (train == test prices there). Using raw
        # market prices here would let window-to-window price drift dominate the
        # result (invalid for short datasets like 14-day AEMO).
        c = buy_slot[τ] * max(0.0, import_kwh) - sell_slot[τ] * max(0.0, -import_kwh)
        cost_total += c
        soc = soc_new
        u_seq[t] = u; soc_seq[t] = soc; cost_seq[t] = c
    end
    return cost_total, u_seq, soc_seq, cost_seq
end

# ---------------------------------------------------------------------------
# Main: per site
# ---------------------------------------------------------------------------
results = []
for site in SITE_IDS
    sdir = joinpath(DATASET_DIR, site)
    try
        train_df = CSV.read(joinpath(sdir, "train.csv"), DataFrame)
        test_df = CSV.read(joinpath(sdir, "test.csv"), DataFrame)
        battery = JSON.parsefile(joinpath(sdir, "battery.json"))
        alpha, beta, support, prob = fit_ar1(train_df)

        z_all = vcat(Float64.(train_df.z), Float64.(test_df.z))
        z_lo, z_hi = extrema(z_all)
        z_range = z_hi - z_lo
        margin = MARGIN * max(z_range, 1e-3)
        z_min = z_lo - margin; z_max = z_hi + margin
        z_axis = range(z_min, z_max, length=NZ)
        power = battery["power_kw"]; capacity = battery["capacity_kwh"]
        dt = 15.0 / 60.0 * (96 / N_SLOTS)
        scale = power * dt / capacity

        # offline cost/dynamics: per-slot average buy/sell price over train
        # (real-time-of-week slot alignment, matching fit_ar1)
        buy_vec = Float64.(train_df.price_buy)
        sell_vec = Float64.(train_df.price_sell)
        n_train = length(buy_vec)
        tau_tr = [week_slot(string(ts), N_SLOTS) for ts in train_df.timestamp]
        buy_by_slot = zeros(HORIZON); sell_by_slot = zeros(HORIZON)
        cnt_slot = zeros(Int, HORIZON)
        for i in 1:n_train
            buy_by_slot[tau_tr[i]] += buy_vec[i]; sell_by_slot[tau_tr[i]] += sell_vec[i]
            cnt_slot[tau_tr[i]] += 1
        end
        for t in 1:HORIZON
            if cnt_slot[t] > 0
                buy_by_slot[t] /= cnt_slot[t]; sell_by_slot[t] /= cnt_slot[t]
            end
        end

        function offline_cost(t::Int, state::Vector{Float64}, control::Vector{Float64}, noise::Vector{Float64})
            z_pred = alpha[t] * state[2] + beta[t] + noise[1]
            import_kwh = control[1] * power * dt + z_pred
            return buy_by_slot[t] * max(0.0, import_kwh) - sell_by_slot[t] * max(0.0, -import_kwh)
        end
        function offline_dyn(t::Int, state::Vector{Float64}, control::Vector{Float64}, noise::Vector{Float64})
            soc = state[1] + (battery["charge_eff"] * max(0.0, control[1]) - max(0.0, -control[1]) / battery["discharge_eff"]) * scale
            z = clamp(alpha[t] * state[2] + beta[t] + noise[1], z_min, z_max)
            return [soc, z]
        end

        noises = StoOpt.Noises(support, prob)
        model = StoOpt.SDP(
            StoOpt.States(HORIZON, 0.0:DX:1.0, z_axis),
            StoOpt.Controls(HORIZON, -1.0:DU:1.0),
            noises, offline_cost, offline_dyn, HORIZON,
        )
        vf = compute_periodic_value_functions(model)

        c_dummy, _, _, _ = replay(model, vf, alpha, beta, z_min, z_max, test_df, battery, :dummy, buy_by_slot, sell_by_slot)
        c_rp, _, _, _ = replay(model, vf, alpha, beta, z_min, z_max, test_df, battery, :rp, buy_by_slot, sell_by_slot)
        c_sdp, u_seq, soc_seq, cost_seq = replay(model, vf, alpha, beta, z_min, z_max, test_df, battery, :sdp, buy_by_slot, sell_by_slot)

        # dispatch-forecast curves: first 2 days of test
        w = min(CURVE_WINDOW, length(test_df.z) - 1)
        actual = Float64.(test_df.z[1:w+1])
        ar1 = Float64[]
        persist = Float64[]
        tau_te2 = [week_slot(string(ts), N_SLOTS) for ts in test_df.timestamp]
        for t in 1:w
            τ = tau_te2[t]
            z_t = clamp(actual[t], z_min, z_max)
            push!(ar1, alpha[τ] * z_t + beta[τ])
            push!(persist, actual[t])
        end

        r = Dict(
            "site" => site,
            "cost" => Dict("dummy" => round(c_dummy; digits=2), "rp" => round(c_rp; digits=2), "sdp" => round(c_sdp; digits=2)),
            "gain" => Dict("rp" => round(c_dummy - c_rp; digits=2), "sdp" => round(c_dummy - c_sdp; digits=2)),
            "curves" => Dict("actual" => round.(actual, digits=3), "ar1" => round.(ar1, digits=3), "persist" => round.(persist, digits=3)),
        )
        open(joinpath(DATASET_DIR, "results", "$site.json"), "w") do io
            JSON.print(io, r)
        end
        flush(stdout); println("site $site: dummy=$(round(c_dummy; digits=1)) rp=$(round(c_rp; digits=1)) sdp=$(round(c_sdp; digits=1)) gain_sdp=$(round(c_dummy-c_sdp; digits=1))")
    catch e
        println("site $site FAILED: ", sprint(showerror, e))
        open(joinpath(DATASET_DIR, "results", "$site.json"), "w") do io
            JSON.print(io, Dict("site" => site, "error" => sprint(showerror, e)))
        end
    end
end

println("done: $(length(results)) sites -> $(joinpath(DATASET_DIR, "results"))")
