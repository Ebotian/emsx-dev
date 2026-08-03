#!/usr/bin/env julia
# Dispatch data: site 1, first N_PERIODS periods — load/PV/z + per-controller
# control AND SOC (S_AR, R_P, R_FE96 physical runs; EXPLOIT = unconstrained).
# MUST run with the EMSx package loaded (JLD2 needs the concrete types to
# read result.control/result.soc correctly — see Project.toml of the repo).
using JLD2, CSV, DataFrames, Statistics
using EMSx

ROOT = "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research"
PUB = "/home/ebt/Downloads/emsx/visualization/public/data"

N_PERIODS = 4            # one period = one week (672 simulated steps)

df = CSV.read(joinpath(ROOT, "dataset/test/1.csv.gz"), DataFrame; stringtype=String)
per = Int.(df.period_id)
# first N_PERIODS distinct periods in file order (ids are non-contiguous, e.g. 1,8,9,11)
picked = unique(per)[1:N_PERIODS]

RUNS = Dict(
    "S_AR" => joinpath(ROOT, "results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/simulate/score.jld2"),
    "R_P" => joinpath(ROOT, "results_sdp/realtime_rollout_cvar_planA_full/realtime_rollout_cvar_planA_full/planA-full-v1/simulate/score.jld2"),
    "R_FE96" => joinpath(ROOT, "results_sdp/realtime_rollout_cvar_h96_full/realtime_rollout_cvar_h96_full/h96-physical-v1/simulate/score.jld2"),
    "EXPLOIT" => joinpath(ROOT, "results_sdp/realtime_rollout_cvar_h96_full/realtime_rollout_cvar_h96_full/h96-full-v1/simulate/score.jld2"),
)

# per-controller: concatenated control+soc over the first N_PERIODS simulations
models = Dict()
for (cid, path) in RUNS
    sims = load(path)["1"]
    length(sims) >= N_PERIODS || error("$(cid): only $(length(sims)) simulations")
    models[cid] = (
        control = reduce(vcat, [sims[k].result.control for k in 1:N_PERIODS]),
        soc = reduce(vcat, [sims[k].result.soc for k in 1:N_PERIODS]),
    )
end

# per-period CSV slice: 768 rows -> 672 simulated steps (h = 768 - 96)
loadv = Float64[]; pvv = Float64[]; zv = Float64[]; tstep = Int[]; pstep = Int[]
for p in picked
    rows = df[findall(==(p), per), :]
    n = size(rows, 1)
    h = n - 96
    l = Float64.(rows.actual_consumption)
    pv = Float64.(rows.actual_pv)
    append!(loadv, l[1:h])
    append!(pvv, pv[1:h])
    append!(zv, [l[min(t + 97, n)] - pv[min(t + 97, n)] for t in 1:h])
    append!(tstep, 1:h)
    append!(pstep, fill(p, h))
end
h = length(tstep)

# sanity: control must vary in [-1,1] (not a misread constant column)
for (cid, m) in models
    @assert minimum(m.control) >= -1 - 1e-9 && maximum(m.control) <= 1 + 1e-9
    @assert length(m.control) == h
end

# TSV (compact, for inspection)
cids = sort(collect(keys(RUNS)))
open(joinpath(PUB, "dispatch.tsv"), "w") do io
    cols = ["t", "period", "load", "pv", "z_settle"]
    println(io, join(cols, "\t"), "\t", join(cids, "\t"))
    for t in 1:h
        vals = [string(round(models[cid].control[t]; digits=4)) for cid in cids]
        println(io, tstep[t], "\t", pstep[t], "\t", round(loadv[t]; digits=2), "\t",
                round(pvv[t]; digits=2), "\t", round(zv[t]; digits=2), "\t", join(vals, "\t"))
    end
end

# JSON (for the site): every step carries load/pv/z + per-controller soc & u
function json_str(x)
    x isa AbstractFloat && return isinteger(x) ? string(Int(x)) : string(x)
    x isa Integer && return string(x)
    x isa AbstractString && return "\"" * x * "\""
    error("unsupported json type: $(typeof(x))")
end
open(joinpath(PUB, "dispatch.json"), "w") do io
    println(io, "{\"site\": \"1\", \"periods\": ", N_PERIODS, ", \"period_ids\": \"", join(picked, ","), "\", \"steps\": [")
    for t in 1:h
        fields = ["\"t\": $(tstep[t])",
                  "\"period\": $(pstep[t])",
                  "\"load\": $(json_str(round(loadv[t]; digits=2)))",
                  "\"pv\": $(json_str(round(pvv[t]; digits=2)))",
                  "\"z\": $(json_str(round(zv[t]; digits=2)))"]
        for cid in cids
            push!(fields, "\"soc_$cid\": $(json_str(round(models[cid].soc[t]; digits=4)))",
                          "\"u_$cid\": $(json_str(round(models[cid].control[t]; digits=4)))")
        end
        println(io, "  {", join(fields, ", "), "}", t < h ? "," : "")
    end
    println(io, "]}")
end

for (cid, m) in models
    u = m.control
    println(cid, ": u min=", round(minimum(u); digits=3), " max=", round(maximum(u); digits=3),
            " (", count(==(-1.0), u), "x -1)  soc min=", round(minimum(m.soc); digits=3),
            " max=", round(maximum(m.soc); digits=3))
end
println("dispatch.json written (site 1, periods ", picked, ", h=", h, ")")
