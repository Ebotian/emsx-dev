#!/usr/bin/env julia
# ============================================================================
# Value-function ratio experiment (clean price-ratio test).
# Fixed AR(1) forecast + demand model. The SDP value function is RETRAINED at
# each training price ratio r_v (peak price x r_v, off-peak fixed), then
# dispatched at each deployment ratio r_d (decision + cost at r_d prices).
# Measures gain(r_v, r_d) and efficiency = gain / gain(r_d, r_d) (the matched
# diagonal = the properly-trained benchmark at r_d). Corrects the price
# mismatch artifact of the earlier mult scan (which used a 1x-trained vf at
# rescaled prices).
# Run with julia -t N (threads over sites). Output: /tmp/probe_vf_ratio.json
# ============================================================================
using JLD2, CSV, DataFrames, Statistics, JSON, Interpolations, LinearAlgebra, Base.Threads
using StoOpt

const ROOT = "/Users/kevin/emsx-experiment"
const TRAIN_DIR = joinpath(ROOT, "dataset", "train")
const TEST_DIR = joinpath(ROOT, "dataset", "test")
const PRICE_CSV = joinpath(ROOT, "EMSx.jl", "metadata", "edf_prices.csv")
const META_CSV = joinpath(ROOT, "dataset", "metadata.csv")
const HORIZON = 672
const DX, DU, NZ, K_NOISE = 0.1, 0.1, 20, 20
const MARGIN = 0.5
const MAX_VI_ITERS, VI_TOL = 30, 1e-3
const RATIOS = [1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 40.0]
const PEAK0 = 0.17
eta_c, eta_d = 0.95, 0.95
soc_axis = 0.0:DX:1.0

prices0 = CSV.read(PRICE_CSV, DataFrame)
buy0 = Float64.(prices0.buy); sell0 = Float64.(prices0.sell)
const IS_PEAK = buy0 .>= PEAK0
meta = CSV.read(META_CSV, DataFrame)
pow_by = Dict(Int(m.site_id) => m.power for m in eachrow(meta))
cap_by = Dict(Int(m.site_id) => m.capacity for m in eachrow(meta))

function interval_sse(ps::Vector{Float64}, pss::Vector{Float64}, a::Int, b::Int)
    n = b - a + 1
    s = ps[b] - (a > 1 ? ps[a-1] : 0.0)
    sq = pss[b] - (a > 1 ? pss[a-1] : 0.0)
    return sq - s * s / n
end

function deterministic_quantize_1d(epsilon::Vector{Float64}, K::Int)
    n = length(epsilon); K = min(K, n)
    s = sort(epsilon)
    ps = zeros(Float64, n); pss = zeros(Float64, n)
    ps[1] = s[1]; pss[1] = s[1]^2
    for i in 2:n
        ps[i] = ps[i-1] + s[i]; pss[i] = pss[i-1] + s[i]^2
    end
    INF = 1e18
    D = fill(INF, K, n); back = zeros(Int, K, n)
    for j in 1:n; D[1, j] = interval_sse(ps, pss, 1, j); end
    for k in 2:K, j in k:n
        best = INF; best_m = k - 1
        for m in (k-1):(j-1)
            c = D[k-1, m] + interval_sse(ps, pss, m+1, j)
            if c < best; best = c; best_m = m; end
        end
        D[k, j] = best; back[k, j] = best_m
    end
    j = n; levels = Vector{Vector{Int}}()
    for k in K:-1:1
        m = back[k, j]; push!(levels, collect((m+1):j)); j = m
    end
    reverse!(levels)
    support = Float64[]; prob = Float64[]
    for idx in levels
        isempty(idx) && continue
        a = idx[1]; b = idx[end]
        s = ps[b] - (a > 1 ? ps[a-1] : 0.0)
        push!(support, s / (b - a + 1)); push!(prob, (b - a + 1) / n)
    end
    return support, prob
end

function fit_linear_noise_model(net_demand::Vector{Float64}, k::Int)
    n = length(net_demand); n_weeks = n ÷ HORIZON
    weeks = collect(reshape(net_demand[1:n_weeks*HORIZON], HORIZON, n_weeks)')   # n_weeks x HORIZON
    is_we = [((t - 1) ÷ 96) + 1 >= 6 for t in 1:HORIZON]
    weights = zeros(2, HORIZON); support = zeros(k, HORIZON); prob = zeros(k, HORIZON)
    for t in 1:HORIZON
        q = (t - 1) % 96 + 1; we = is_we[t]
        xs = Float64[]; ys = Float64[]
        for w in 1:n_weeks, tt in 1:HORIZON
            if (tt - 1) % 96 + 1 == q && is_we[tt] == we
                push!(xs, tt == 1 ? weeks[w, HORIZON] : weeks[w, tt-1])
                push!(ys, weeks[w, tt])
            end
        end
        X = hcat(xs, ones(length(xs)))
        wreg = pinv(X'X) * X' * ys
        weights[1, t] = wreg[1]; weights[2, t] = wreg[2]
        eps = ys - X * wreg
        supp, pr = deterministic_quantize_1d(eps, k)
        for i in 1:k
            if i <= length(supp)
                support[i, t] = supp[i]; prob[i, t] = pr[i]
            else
                support[i, t] = supp[end]; prob[i, t] = 0.0
            end
        end
    end
    return weights, support, prob
end

function make_periodic_final_cost(model, vf_step1)
    ax1 = model.states.axis[1]; ax2 = model.states.axis[2]
    itp = linear_interpolation((ax1, ax2), vf_step1; extrapolation_bc=Line())
    return (state::Vector{Float64}) -> itp(state[1], state[2])
end

function compute_vf(model)
    vf = StoOpt.compute_value_functions(model)
    prev_v1 = copy(vf[1])
    for _ in 1:MAX_VI_ITERS
        model.final_cost = make_periodic_final_cost(model, vf[1])
        vf = StoOpt.compute_value_functions(model)
        cur = vf[1]
        shape = maximum(abs.((cur .- mean(cur)) .- (prev_v1 .- mean(prev_v1))))
        shape < VI_TOL && break
        prev_v1 = copy(cur)
    end
    model.final_cost = nothing
    return vf
end

function decide(u_grid, zhat, soc, itp, b, s, E, scale)
    best = Inf; bestu = 0.0
    for u in u_grid
        soc_n = soc + (eta_c * max(0.0, u) - max(0.0, -u) / eta_d) * scale
        (0.0 <= soc_n <= 1.0) || continue
        imp = zhat + u * E
        c = b * max(0.0, imp) - s * max(0.0, -imp) + itp(soc_n, zhat)
        if c < best; best = c; bestu = u; end
    end
    return bestu
end

function main()
    NR = length(RATIOS)
    site_results = [Matrix{Tuple{Float64,Float64}}(undef, NR, NR) for _ in 1:70]
    @threads for sid in 1:70
        train = CSV.read(joinpath(TRAIN_DIR, "$(sid).csv.gz"), DataFrame)
        test = CSV.read(joinpath(TEST_DIR, "$(sid).csv.gz"), DataFrame)
        net_tr = Float64.(train.actual_consumption .- train.actual_pv)
        weights, support, prob = fit_linear_noise_model(net_tr, K_NOISE)
        alpha = weights[1, :]; beta = weights[2, :]
        nw = length(net_tr) ÷ HORIZON
        zvals = vec(reshape(net_tr[1:nw*HORIZON], HORIZON, nw))
        z_lo, z_hi = extrema(zvals)
        zr = z_hi - z_lo; margin = MARGIN * max(zr, 1e-3)
        zmin = z_lo - margin; zmax = z_hi + margin
        z_axis = range(zmin, zmax, length=NZ)
        power = pow_by[sid]; capacity = cap_by[sid]
        E = power * 0.25; scale = E / capacity
        u_grid = -1.0:DU:1.0
        noises = StoOpt.Noises(support, prob)

        # train the value function at each training ratio
        vfs = Dict{Float64,Any}()
        for rv in RATIOS
            buy_v = [IS_PEAK[i] ? buy0[i] * rv : buy0[i] for i in eachindex(buy0)]
            sell_v = [IS_PEAK[i] ? sell0[i] * rv : sell0[i] for i in eachindex(sell0)]
            function off_cost(t, state, control, noise)
                z_pred = alpha[t] * state[2] + beta[t] + noise[1]
                imp = control[1] * power * 0.25 + z_pred
                return buy_v[t] * max(0.0, imp) - sell_v[t] * max(0.0, -imp)
            end
            function off_dyn(t, state, control, noise)
                soc_n = state[1] + (eta_c * max(0.0, control[1]) - max(0.0, -control[1]) / eta_d) * scale
                z = clamp(alpha[t] * state[2] + beta[t] + noise[1], zmin, zmax)
                return [soc_n, z]
            end
            model = StoOpt.SDP(
                StoOpt.States(HORIZON, soc_axis, z_axis),
                StoOpt.Controls(HORIZON, -1.0:DU:1.0),
                noises, off_cost, off_dyn, HORIZON)
            vfs[rv] = compute_vf(model)
        end

        # dispatch at each deployment ratio with each training-ratio vf
        itps_cache = Dict{Float64,Vector{Any}}()
        for (rd_idx, rd) in enumerate(RATIOS)
            buy_d = [IS_PEAK[i] ? buy0[i] * rd : buy0[i] for i in eachindex(buy0)]
            sell_d = [IS_PEAK[i] ? sell0[i] * rd : sell0[i] for i in eachindex(sell0)]
            for (rv_idx, rv) in enumerate(RATIOS)
                if !haskey(itps_cache, rv)
                    vf = vfs[rv].functions
                    itps_cache[rv] = [linear_interpolation((soc_axis, z_axis), vf[t+1, :, :]; extrapolation_bc=Line()) for t in 1:HORIZON]
                end
                itps = itps_cache[rv]
                soc = 0.0; cost = 0.0; cost_d = 0.0; wmae = 0.0; nd = 0
                for g in groupby(test, :period_id)
                    rows = g; n = nrow(rows); h = n - 96
                    for t in 1:h
                        r_tgt = min(t + 97, n)
                        z_cur = rows.actual_consumption[t+96] - rows.actual_pv[t+96]
                        z_tgt = rows.actual_consumption[r_tgt] - rows.actual_pv[r_tgt]
                        za = clamp(alpha[t] * z_cur + beta[t], zmin, zmax)
                        wmae += buy_d[t] * abs(za - z_tgt); nd += 1
                        u = decide(u_grid, za, soc, itps[t], buy_d[t], sell_d[t], E, scale)
                        soc_n = soc + (eta_c * max(0.0, u) - max(0.0, -u) / eta_d) * scale
                        soc = max(0.0, min(1.0, soc_n))
                        cost += buy_d[t] * max(0.0, z_tgt + u * E) - sell_d[t] * max(0.0, -(z_tgt + u * E))
                        cost_d += buy_d[t] * max(0.0, z_tgt) - sell_d[t] * max(0.0, -z_tgt)
                    end
                end
                site_results[sid][rv_idx, rd_idx] = (cost_d - cost, wmae / nd)
            end
        end
    end

    # aggregate
    agg = Dict{String,Any}()
    for (rv_idx, rv) in enumerate(RATIOS), (rd_idx, rd) in enumerate(RATIOS)
        gains = [site_results[s][rv_idx, rd_idx][1] for s in 1:70]
        wmaes = [site_results[s][rv_idx, rd_idx][2] for s in 1:70]
        diag_gain = mean([site_results[s][rd_idx, rd_idx][1] for s in 1:70])
        agg["$(rv)_$(rd)"] = Dict("rv" => rv, "rd" => rd,
            "gain" => mean(gains), "wmae" => mean(wmaes),
            "efficiency" => diag_gain > 0 ? mean(gains) / diag_gain : NaN,
            "gain_by_site" => gains)
    end
    open("/tmp/probe_vf_ratio.json", "w") do io
        JSON.print(io, agg, 2)
    end
    println("saved /tmp/probe_vf_ratio.json (threads=", Threads.nthreads(), ")")
end

main()
