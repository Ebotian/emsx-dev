#!/usr/bin/env julia
# Price-multiplier scan: peak price x mult, off-peak fixed; re-run the decisive
# probe (price-weighted forecast error + dispatch costs + dWMAE-vs-dcost corr)
# to find at which peak/off-peak ratio the price-weighting starts to matter.
using JLD2, CSV, DataFrames, Statistics, JSON, Interpolations

const ROOT = "/Users/kevin/emsx-experiment"
const VF_DIR = joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20", "value_functions")
const TEST_DIR = joinpath(ROOT, "dataset", "test")
const PRICE_CSV = joinpath(ROOT, "EMSx.jl", "metadata", "edf_prices.csv")
const META_CSV = joinpath(ROOT, "dataset", "metadata.csv")
prices = CSV.read(PRICE_CSV, DataFrame)
buy0 = Float64.(prices.buy); sell0 = Float64.(prices.sell)
PEAK0 = 0.17
IS_PEAK = buy0 .>= PEAK0
meta = CSV.read(META_CSV, DataFrame)
pow_by = Dict(Int(m.site_id) => m.power for m in eachrow(meta))
cap_by = Dict(Int(m.site_id) => m.capacity for m in eachrow(meta))
eta_c, eta_d = 0.95, 0.95
const DX = 0.1; const NZ = 20; const DU = 0.1; const DT = 0.25
soc_axis = 0.0:DX:1.0

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

function run_scan(buy, sell)
sites = Dict{String,Any}[]
for sid in 1:70
    df = CSV.read(joinpath(TEST_DIR, "$(sid).csv.gz"), DataFrame)
    payload = JLD2.load(joinpath(VF_DIR, "$(sid).jld2"))
    alpha = Vector{Float64}(payload["alpha"]); beta = Vector{Float64}(payload["beta"])
    zmin = payload["z_min"]; zmax = payload["z_max"]
    vf = payload["value_function"].functions
    z_axis = range(zmin, zmax, length=NZ)
    itps = [linear_interpolation((soc_axis, z_axis), vf[t+1, :, :]; extrapolation_bc=Line()) for t in 1:672]
    power = pow_by[sid]; capacity = cap_by[sid]
    E = power * DT; scale = E / capacity
    u_grid = -1.0:DU:1.0
    acc = Dict{String,Any}(
        "ar1" => Dict("n" => 0, "e" => 0.0, "we" => 0.0, "t" => [0.0, 0.0]),
        "pers" => Dict("n" => 0, "e" => 0.0, "we" => 0.0, "t" => [0.0, 0.0]),
        "se" => Dict("n" => 0, "e" => 0.0, "we" => 0.0, "t" => [0.0, 0.0]),
    )
    policies = Dict("ar1" => (soc=0.0, cost=0.0), "se" => (soc=0.0, cost=0.0),
                    "pers" => (soc=0.0, cost=0.0), "dummy" => (soc=0.0, cost=0.0))
    for g in groupby(df, :period_id)
        rows = g; n = nrow(rows); h = n - 96
        for t in 1:h
            r_tgt = min(t + 97, n)
            z_cur = rows.actual_consumption[t+96] - rows.actual_pv[t+96]
            z_tgt = rows.actual_consumption[r_tgt] - rows.actual_pv[r_tgt]
            za_raw = alpha[t] * z_cur + beta[t]
            zs_raw = Float64(rows.load_00[r_tgt] - rows.pv_00[r_tgt])
            za = clamp(za_raw, zmin, zmax); zs = clamp(zs_raw, zmin, zmax); zp = clamp(z_cur, zmin, zmax)
            b = buy[t]; s = sell[t]
            tq = IS_PEAK[t] ? 2 : 1   # peak/off-peak bucket from the base 2-level TOU
            for (k, zraw, zhat) in (("ar1", za_raw, za), ("pers", z_cur, zp), ("se", zs_raw, zs))
                e = abs(zraw - z_tgt)
                acc[k]["n"] += 1; acc[k]["e"] += e; acc[k]["we"] += b * e; acc[k]["t"][tq] += e
            end
            ua = decide(u_grid, za, policies["ar1"].soc, itps[t], b, s, E, scale)
            us = decide(u_grid, zs, policies["se"].soc, itps[t], b, s, E, scale)
            up = decide(u_grid, zp, policies["pers"].soc, itps[t], b, s, E, scale)
            for (k, u) in (("ar1", ua), ("se", us), ("pers", up), ("dummy", 0.0))
                pol = policies[k]
                soc_n = pol.soc + (eta_c * max(0.0, u) - max(0.0, -u) / eta_d) * scale
                policies[k] = (soc=max(0.0, min(1.0, soc_n)),
                    cost=pol.cost + b * max(0.0, z_tgt + u * E) - s * max(0.0, -(z_tgt + u * E)))
            end
        end
    end
    mks(k) = (a = acc[k]; n = a["n"];
        Dict("mae" => a["e"] / n, "wmae" => a["we"] / n, "pk" => a["t"][2] / n))
    push!(sites, Dict("site" => sid,
        "ar1" => mks("ar1"), "pers" => mks("pers"), "se" => mks("se"),
        "cost" => Dict("ar1" => policies["ar1"].cost, "se" => policies["se"].cost,
                       "pers" => policies["pers"].cost, "dummy" => policies["dummy"].cost)))
end
# aggregate: means + correlations of dWMAE/dMAE vs dcost (se vs ar1)
corr(x, y) = (n = length(x); mx = sum(x)/n; my = sum(y)/n;
    sx = sqrt(sum((x .- mx).^2)); sy = sqrt(sum((y .- my).^2));
    sx > 0 && sy > 0 ? sum((x .- mx) .* (y .- my)) / (sx * sy) : NaN)
dmae = [s["se"]["mae"] - s["ar1"]["mae"] for s in sites]
dwmae = [s["se"]["wmae"] - s["ar1"]["wmae"] for s in sites]
dcost = [s["cost"]["se"] - s["cost"]["ar1"] for s in sites]
costs = Dict(k => mean(s["cost"][k] for s in sites) for k in ("ar1", "se", "pers", "dummy"))
return Dict(
    "cost" => costs,
    "d_se_ar1" => Dict("mean" => mean(dcost), "neg" => count(<(0.0), dcost)),
    "corr" => Dict("dmae" => corr(dmae, dcost), "dwmae" => corr(dwmae, dcost)),
    "wmae" => Dict(k => mean(s[k]["wmae"] for s in sites) for k in ("ar1", "se", "pers")),
    "mae" => Dict(k => mean(s[k]["mae"] for s in sites) for k in ("ar1", "se", "pers")),
)
end

results = Dict{String,Any}()
for mult in [1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 40.0]
    buy = [IS_PEAK[i] ? buy0[i] * mult : buy0[i] for i in eachindex(buy0)]
    sell = [IS_PEAK[i] ? sell0[i] * mult : sell0[i] for i in eachindex(sell0)]
    results[string(mult)] = run_scan(buy, sell)
    r = results[string(mult)]
    c = r["cost"]; d = r["d_se_ar1"]
    println("mult=$(mult): gain ar1=$(round(c["dummy"]-c["ar1"]; digits=1)) "
            * "se=$(round(c["dummy"]-c["se"]; digits=1)) pers=$(round(c["dummy"]-c["pers"]; digits=1)) "
            * "| SE-ar1=$(round(d["mean"]; digits=1)) (SE更好 $(d["neg"]))/70 "
            * "| corr(dwmae,dcost)=$(round(r["corr"]["dwmae"]; digits=3)) "
            * "corr(dmae,dcost)=$(round(r["corr"]["dmae"]; digits=3))")
end
open("/tmp/probe_scan.json", "w") do io
    JSON.print(io, results, 2)
end
println("saved /tmp/probe_scan.json")
