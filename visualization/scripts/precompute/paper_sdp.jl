#!/usr/bin/env julia
# Paper SDP controller (soc-only offline value function, no AR state)
# under the continuous-SOC convention.  Per site:
#   1) offline net-demand law: per (quarter-of-day, weekday/weekend) group,
#      k-level discrete distribution from training weeks.
#   2) soc-only VF via StoOpt (States = [0,1] SOC grid; cost uses noise[1]).
#   3) continuous-SOC simulate: StoOpt.compute_control at each step.
# Usage: julia paper_sdp.jl <site> [dx] [du] [k]
using EMSx, StoOpt, CSV, DataFrames, Statistics, JLD2

ROOT = get(ENV, "EMSX_DATA_ROOT", "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research")
function path_of(parts...)
    cand = joinpath(ROOT, parts...)
    ispath(cand) ? cand : joinpath(ROOT, parts[end])
end

const DX = length(ARGS) > 1 ? parse(Float64, ARGS[2]) : 0.1
const DU = length(ARGS) > 2 ? parse(Float64, ARGS[3]) : 0.1
const K = length(ARGS) > 3 ? parse(Int, ARGS[4]) : 20
const HORIZON = 672

function train_weeks(sid)
    p = path_of("dataset", "train", "$(sid).csv.gz")
    df = CSV.read(p, DataFrame)
    z = Float64.(df.actual_consumption .- df.actual_pv)
    n = length(z); nw = n ÷ HORIZON
    nw >= 2 || error("not enough training weeks for site $(sid)")
    return reshape(z[1:nw*HORIZON], HORIZON, nw)
end

function offline_law(zw::Matrix{Float64}, t::Int)
    # group by quarter-of-day and weekday/weekend (origin at t)
    q = mod(t - 1, 96) + 1
    wd = mod(div(t - 1, 96), 7) >= 5  # weekend
    nw = size(zw, 2)
    vals = Float64[]
    for w in 1:nw
        tt = t
        wd_actual = mod(div(tt - 1, 96), 7) >= 5
        wd_actual == wd || continue
        mod(tt - 1, 96) + 1 == q || continue
        push!(vals, zw[tt, w])
    end
    isempty(vals) && return (zeros(K), fill(1.0 / K, K))
    # deterministic k-level weighted quantiles
    ks = sort(collect(range(0.0, 1.0; length=K + 1)))[2:end]
    qs = [quantile(vals, a) for a in ks]
    probs = fill(1.0 / K, K)
    return (qs, probs)
end

function calibrate_site(sid)
    zw = train_weeks(sid)
    meta = CSV.read(path_of("dataset", "metadata.csv"), DataFrame)
    mrow = meta[meta.site_id .== sid, :]
    _ec = Float64(mrow.charge_efficiency[1])
    _ed = Float64(mrow.discharge_efficiency[1])
    _P = Float64(mrow.power[1])
    _C = Float64(mrow.capacity[1])
    prices_df = CSV.read(path_of("EMSx.jl", "metadata", "edf_prices.csv"), DataFrame)
    prices = EMSx.Prices("edf", prices_df[!, 2], prices_df[!, 3])
    # noises: per-t random variable from offline law (2D: cardinal x horizon)
    support = zeros(K, HORIZON)
    probability = zeros(K, HORIZON)
    for t in 1:HORIZON
        qs, ps = offline_law(zw, t)
        support[:, t] = qs
        probability[:, t] = ps
    end
    noises = StoOpt.Noises(support, probability)
    _s = _P * 0.25 / _C
    _buy = prices.buy
    _sell = prices.sell
    function sdp_dynamics(t::Int, state::Array{Float64,1}, control::Array{Float64,1}, noise::Array{Float64,1})
        return [state[1] + (_ec * max(0.0, control[1]) - max(0.0, -control[1]) / _ed) * _s]
    end
    function sdp_cost(t::Int, state::Array{Float64,1}, control::Array{Float64,1}, noise::Array{Float64,1})
        import_kwh = control[1] * _P * 0.25 + noise[1]
        return _buy[t] * max(0.0, import_kwh) - _sell[t] * max(0.0, -import_kwh)
    end
    model = StoOpt.SDP(
        StoOpt.States(HORIZON, 0.0:DX:1.0),
        StoOpt.Controls(HORIZON, -1.0:DU:1.0),
        noises,
        sdp_cost,
        sdp_dynamics,
        HORIZON,
    )
    vf = StoOpt.compute_value_functions(model)
    return prices, model, vf
end

function simulate_site(sid)
    prices, model, vf = calibrate_site(sid)
    meta = CSV.read(path_of("dataset", "metadata.csv"), DataFrame)
    row = findfirst(==(string(sid)), string.(meta[!, :site_id]))
    test_root = path_of("dataset", "test")
    site = EMSx.Site(meta, row, test_root, nothing, "x")
    test_data, site_visible = EMSx.load_site_data(site)
    periods = unique(test_data[!, :period_id])
    soc = 0.0
    total = 0.0
    for pid in periods
        td = test_data[test_data.period_id .== pid, :]
        period = EMSx.Period(string(pid), td, site_visible)
        h = size(period.data, 1) - 96
        for t in 1:h
            u = StoOpt.compute_control(
                model, t, [soc],
                StoOpt.RandomVariable(model.noises, t), vf,
            )[1]
            stage, soc = EMSx.apply_control(t, h, prices, period, soc, u)
            total += stage
        end
    end
    return total / length(periods)
end

if abspath(PROGRAM_FILE) == @__FILE__
    sid = parse(Int, ARGS[1])
    cost = simulate_site(sid)
    println("SDP site $sid mean period cost = $cost")
end
