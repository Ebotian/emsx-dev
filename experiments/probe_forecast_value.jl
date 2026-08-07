#!/usr/bin/env julia
# ============================================================================
# Decisive experiments on the S_AR dispatch framework (70 EMSx sites).
#
# Experiment 1 — price-weighted one-step forecast error.
#   For AR(1), persistence and the dataset SE(k=1) forecast (corrected
#   alignment: load_00 of the TARGET row), measure MAE, price-weighted MAE
#   (weight = buy price at the decision step, the stage-cost sensitivity) and
#   the error split across price terciles. Answers: does price-weighting
#   change the forecast ranking, and where is each forecast's advantage?
#
# Experiment 2 — transmission coefficient (forecast -> action).
#   At every decision step, compute the SDP argmin u* under the value
#   function for the AR(1) forecast vs the SE forecast (same state/SOC),
#   and measure |Δu*|, its price-weighted impact, and the fraction of steps
#   where the forecast choice changes the action. Answers: does a better
#   forecast actually change dispatch decisions, and at what price-weighted
#   magnitude?
# ============================================================================
using JLD2, CSV, DataFrames, Statistics, JSON, Interpolations

const ROOT = "/Users/kevin/emsx-experiment"
const VF_DIR = joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20", "value_functions")
const TEST_DIR = joinpath(ROOT, "dataset", "test")
const PRICE_CSV = joinpath(ROOT, "EMSx.jl", "metadata", "edf_prices.csv")
const META_CSV = joinpath(ROOT, "dataset", "metadata.csv")

prices = CSV.read(PRICE_CSV, DataFrame)
buy = Float64.(prices.buy); sell = Float64.(prices.sell)
meta = CSV.read(META_CSV, DataFrame)
pow_by = Dict(Int(m.site_id) => m.power for m in eachrow(meta))
cap_by = Dict(Int(m.site_id) => m.capacity for m in eachrow(meta))
eta_c, eta_d = 0.95, 0.95

const DX = 0.1; const NZ = 20; const DU = 0.1; const DT = 0.25
soc_axis = 0.0:DX:1.0
PEAK = 0.17   # EDF 2-level TOU: 0.17 peak / 0.13 off-peak (€/kWh)

function decide(u_grid, zhat, soc, itp, b, s, E, scale)
    best = Inf; bestu = 0.0
    for u in u_grid
        soc_n = soc + (eta_c * max(0.0, u) - max(0.0, -u) / eta_d) * scale
        (0.0 <= soc_n <= 1.0) || continue
        imp = zhat + u * E
        c = b * max(0.0, imp) - s * max(0.0, -imp) + itp(soc_n, zhat)
        if c < best
            best = c; bestu = u
        end
    end
    return bestu
end

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
    E = power * DT
    scale = E / capacity
    u_grid = -1.0:DU:1.0

    acc = Dict{String,Any}(
        "ar1" => Dict("n" => 0, "e" => 0.0, "e2" => 0.0, "we" => 0.0, "t" => [0.0, 0.0]),
        "pers" => Dict("n" => 0, "e" => 0.0, "e2" => 0.0, "we" => 0.0, "t" => [0.0, 0.0]),
        "se" => Dict("n" => 0, "e" => 0.0, "e2" => 0.0, "we" => 0.0, "t" => [0.0, 0.0]),
    )
    ndec = 0; n_chg = 0; du_sum = 0.0; wdu_sum = 0.0
    # four policies: ar1 / se / pers / dummy — each with its own SOC path and cost
    policies = Dict("ar1" => (soc=0.0, cost=0.0), "se" => (soc=0.0, cost=0.0),
                    "pers" => (soc=0.0, cost=0.0), "dummy" => (soc=0.0, cost=0.0))
    for g in groupby(df, :period_id)
        rows = g
        n = nrow(rows); h = n - 96
        for t in 1:h
            r_tgt = min(t + 97, n)   # apply_control clamps the target row
            z_cur = rows.actual_consumption[t+96] - rows.actual_pv[t+96]
            z_tgt = rows.actual_consumption[r_tgt] - rows.actual_pv[r_tgt]
            za_raw = alpha[t] * z_cur + beta[t]
            zs_raw = Float64(rows.load_00[r_tgt] - rows.pv_00[r_tgt])
            za = clamp(za_raw, zmin, zmax)
            zs = clamp(zs_raw, zmin, zmax)
            zp = clamp(z_cur, zmin, zmax)
            b = buy[t]; s = sell[t]
            tq = b >= PEAK ? 2 : 1   # 2-level TOU: peak / off-peak
            for (k, zraw, zhat) in (("ar1", za_raw, za), ("pers", z_cur, zp), ("se", zs_raw, zs))
                e = abs(zraw - z_tgt)
                acc[k]["n"] += 1; acc[k]["e"] += e; acc[k]["e2"] += e^2
                acc[k]["we"] += b * e; acc[k]["t"][tq] += e
            end
            ua = decide(u_grid, za, policies["ar1"].soc, itps[t], b, s, E, scale)
            us = decide(u_grid, zs, policies["se"].soc, itps[t], b, s, E, scale)
            up = decide(u_grid, zp, policies["pers"].soc, itps[t], b, s, E, scale)
            du = abs(ua - us)
            ndec += 1
            if du > 0
                n_chg += 1; du_sum += du; wdu_sum += b * du
            end
            # real stage cost for each policy (target demand z_tgt, actual prices)
            for (k, u) in (("ar1", ua), ("se", us), ("pers", up), ("dummy", 0.0))
                pol = policies[k]
                soc_n = pol.soc + (eta_c * max(0.0, u) - max(0.0, -u) / eta_d) * scale
                pol = (soc=max(0.0, min(1.0, soc_n)),
                       cost=pol.cost + b * max(0.0, z_tgt + u * E) - s * max(0.0, -(z_tgt + u * E)))
                policies[k] = pol
            end
        end
    end
    mks(k) = (a = acc[k]; n = a["n"];
        Dict("mae" => a["e"] / n, "rmse" => sqrt(a["e2"] / n), "wmae" => a["we"] / n,
             "pk" => a["t"][2] / n))   # peak-period mean error
    push!(sites, Dict("site" => sid,
        "ar1" => mks("ar1"), "pers" => mks("pers"), "se" => mks("se"),
        "trans" => Dict("frac" => n_chg / ndec, "mean_du" => du_sum / ndec,
                        "wmean_du" => wdu_sum / ndec),
        "cost" => Dict("ar1" => policies["ar1"].cost, "se" => policies["se"].cost,
                       "pers" => policies["pers"].cost, "dummy" => policies["dummy"].cost)))
end

# ---- aggregate ----
agg = Dict{String,Any}("sites" => sites)
for k in ("ar1", "pers", "se")
    agg[k] = Dict(
        "mae" => mean(s[k]["mae"] for s in sites),
        "rmse" => mean(s[k]["rmse"] for s in sites),
        "wmae" => mean(s[k]["wmae"] for s in sites),
        "pk" => mean(s[k]["pk"] for s in sites),
    )
end
agg["trans"] = Dict(
    "frac" => mean(s["trans"]["frac"] for s in sites),
    "mean_du" => mean(s["trans"]["mean_du"] for s in sites),
    "wmean_du" => mean(s["trans"]["wmean_du"] for s in sites),
)
agg["cost"] = Dict(k => mean(s["cost"][k] for s in sites) for k in ("ar1", "se", "pers", "dummy"))
# ranking under both metrics
wins = Dict("mae" => Dict{String,Int}(), "wmae" => Dict{String,Int}(), "rmse" => Dict{String,Int}(), "pk" => Dict{String,Int}())
for k in ("ar1", "pers", "se")
    for met in ("mae", "wmae", "rmse", "pk")
        wins[met][k] = sum(s[k][met] < s[m][met] for s in sites for m in ("ar1", "pers", "se") if m != k)
    end
end
agg["wins"] = wins

open("/tmp/probe_forecast_value.json", "w") do io
    JSON.print(io, agg, 2)
end

println("=== 实验1：预测误差（全 70 站均值；EDF 两级电价 0.13/0.17 €/kWh） ===")
for k in ("ar1", "pers", "se")
    a = agg[k]
    mae = round(a["mae"]; digits=3); rm = round(a["rmse"]; digits=3)
    wmae = round(a["wmae"]; digits=3); pk = round(a["pk"]; digits=3)
    println("  $k: MAE=$mae RMSE=$rm 价格加权MAE=$wmae 峰时段误差=$pk")
end
for met in ("mae", "rmse", "wmae", "pk")
    println("  按 $met 最优的成对胜出数: ", wins[met])
end
println()
println("=== 实验2：传导 + 端到端调度成本（全 70 站均值） ===")
t = agg["trans"]
f = round(t["frac"]*100; digits=1); d = round(t["mean_du"]; digits=3); wd = round(t["wmean_du"]; digits=3)
println("  动作改变占比: $f%  平均 |Δu|: $d  价格加权平均: $wd")
c = agg["cost"]
for k in ("dummy", "pers", "ar1", "se")
    println("  调度成本($k): $(round(c[k]; digits=1))")
end
println("  gain(相对 dummy): ar1=$(round(c["dummy"]-c["ar1"]; digits=1))  "
        * "se=$(round(c["dummy"]-c["se"]; digits=1))  pers=$(round(c["dummy"]-c["pers"]; digits=1))")
println("  SE−AR1 成本差: $(round(c["se"]-c["ar1"]; digits=1))  （<0 表示 SE 预测更优）")
