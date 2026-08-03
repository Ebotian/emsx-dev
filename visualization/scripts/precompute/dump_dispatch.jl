#!/usr/bin/env julia
# Dispatch data: site 1, first period — load/PV/z + per-controller control
# (S_AR, R_P, R_FE96 from physical runs; EXPLOIT = unconstrained h96-full-v1).
using JLD2, CSV, DataFrames, Statistics

ROOT = "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research"
PUB = "/home/ebt/Downloads/emsx/visualization/public/data"

df = CSV.read(joinpath(ROOT, "dataset/test/1.csv.gz"), DataFrame; stringtype=String)
per = Int.(df.period_id)
idx = findall(==(1), per)
rows = df[idx, :]
n = size(rows, 1)
h = n - 96
loadv = Float64.(rows.actual_consumption)
pvv = Float64.(rows.actual_pv)
z_settle = [loadv[min(t + 97, n)] - pvv[min(t + 97, n)] for t in 1:h]

RUNS = Dict(
    "S_AR" => joinpath(ROOT, "results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/simulate/score.jld2"),
    "R_P" => joinpath(ROOT, "results_sdp/realtime_rollout_cvar_planA_full/realtime_rollout_cvar_planA_full/planA-full-v1/simulate/score.jld2"),
    "R_FE96" => joinpath(ROOT, "results_sdp/realtime_rollout_cvar_h96_full/realtime_rollout_cvar_h96_full/h96-physical-v1/simulate/score.jld2"),
    "EXPLOIT" => joinpath(ROOT, "results_sdp/realtime_rollout_cvar_h96_full/realtime_rollout_cvar_h96_full/h96-full-v1/simulate/score.jld2"),
)

# load once per controller
models = Dict(cid => load(path)["1"][1].result.control for (cid, path) in RUNS)

open(joinpath(PUB, "dispatch.tsv"), "w") do io
    println(io, "t\tload\tpv\tz_settle\t", join(collect(keys(RUNS)), "\t"))
    for t in 1:h
        vals = [string(round(models[cid][t]; digits=4)) for cid in keys(RUNS)]
        println(io, t, "\t", round(loadv[t]; digits=2), "\t", round(pvv[t]; digits=2), "\t",
                round(z_settle[t]; digits=2), "\t", join(vals, "\t"))
    end
end
println("dispatch.tsv written (h=", h, ")")
