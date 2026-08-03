#!/usr/bin/env julia
# Per-site persistence/AR R2 and score deltas (for the sensitivity page).
using JLD2, CSV, DataFrames, Statistics
ROOT = "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research"
PUB = "/home/ebt/Downloads/emsx/visualization/public/data"
lp = CSV.read("/tmp/physical_lp_oracle.csv", DataFrame)
du = CSV.read(joinpath(ROOT, "results_sdp/dp_upper_bound_v1/scores_full.csv"), DataFrame)
du.site = parse.(Int, string.(du.site))
rp = load(joinpath(ROOT, "results_sdp/realtime_rollout_cvar_planA_full/realtime_rollout_cvar_planA_full/planA-full-v1/simulate/score.jld2"))
base = load(joinpath(ROOT, "results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/simulate/score.jld2"))
function r2s(sid)
    vf = JLD2.load(joinpath(ROOT, "results_sdp/sweep_wdwe2_k20/value_functions/$(sid).jld2"))
    alpha = vf["alpha"]; beta = vf["beta"]
    df = CSV.read(joinpath(ROOT, "dataset/train/$(sid).csv.gz"), DataFrame)
    z = Float64.(df.actual_consumption .- df.actual_pv)
    n = length(z); nw = n ÷ 672
    nw >= 2 || return (NaN, NaN)
    zw = reshape(z[1:nw*672], 672, nw)
    total2 = sum((zw .- mean(zw)) .^ 2)
    rp2 = sum((zw[2:end,:] .- zw[1:end-1,:]) .^ 2)
    ra2 = 0.0
    for t in 2:672, w in 1:nw
        ra2 += (zw[t,w] - (alpha[t]*zw[t-1,w] + beta[t]))^2
    end
    return (1 - ra2/total2, 1 - rp2/total2)
end
function score(model, sid)
    mc = mean(Float64[sum(sim.result.cost) for sim in model[string(sid)]])
    d = du[du.site .== sid, :].dummy_per[1]
    u = lp[lp.site .== sid, :].lp_upper[1]
    return (d - mc) / (d - u)
end
open(joinpath(PUB, "sensitivity_persist.tsv"), "w") do io
    println(io, "site\tdr2\tds")
    for sid in 1:70
        r2a, r2p = r2s(sid)
        (isnan(r2a) || isnan(r2p)) && continue
        ds = score(rp, sid) - score(base, sid)
        println(io, sid, "\t", round(r2a - r2p; digits=6), "\t", round(ds; digits=6))
    end
end
println("sensitivity_persist.tsv written")
