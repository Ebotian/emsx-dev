#!/usr/bin/env julia
# Dump per-site costs (S_AR/R_P/R_FE96) and representative process series
# (site 1, first period) as TSV for the visualization data (stage 3).
using JLD2, Statistics

ROOT = "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research"
PUB = "/home/ebt/Downloads/emsx/visualization/public/data"
RUNS = Dict(
    "S_AR" => joinpath(ROOT, "results_sdp/runs/local_wdwe2_k20_locked_v1/recalibrated-v1/simulate/score.jld2"),
    "R_P" => joinpath(ROOT, "results_sdp/realtime_rollout_cvar_planA_full/realtime_rollout_cvar_planA_full/planA-full-v1/simulate/score.jld2"),
    "R_FE96" => joinpath(ROOT, "results_sdp/realtime_rollout_cvar_h96_full/realtime_rollout_cvar_h96_full/h96-physical-v1/simulate/score.jld2"),
)

site_cost(model, sid) = mean(sum(sim.result.cost) for sim in model[string(sid)])

mkpath(PUB)
mkpath(joinpath(PUB, "process"))
for (cid, path) in RUNS
    m = load(path)
    open(joinpath(PUB, "ours_$(cid).tsv"), "w") do io
        for s in 1:70
            println(io, s, "\t", round(site_cost(m, s); digits=4))
        end
    end
    # process: site 1, first period
    sims = m["1"]
    isempty(sims) && continue
    sim = sims[1]
    n = length(sim.result.cost)
    cum = 0.0
    open(joinpath(PUB, "process", "$(cid).tsv"), "w") do io
        println(io, "t\tsoc\tu\tcost\tcumCost")
        for t in 1:n
            cum += sim.result.cost[t]
            println(io, t, "\t", round(sim.result.soc[t]; digits=4), "\t",
                    round(sim.result.control[t]; digits=4), "\t",
                    round(sim.result.cost[t]; digits=4), "\t", round(cum; digits=2))
        end
    end
end
println("ours TSVs + process TSVs written")
