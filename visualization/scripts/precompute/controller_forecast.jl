#!/usr/bin/env julia
# ============================================================================
# Controller one-step forecast comparison — test set, out-of-sample (70 sites)
# ============================================================================
# Evaluates the forecast actually used by the S_AR controller:
#   - AR(1):      ẑ = alpha[τ]·z_τ + beta[τ]   (τ = period-internal step,
#                exactly as the online controller indexes alpha/beta)
#   - SE(k=1):    ẑ = load_00 − pv_00 (row r)  (dataset's own day-ahead
#                forecast column, "issued at row r, targets row r+1")
#   - persistence: ẑ = z_τ                     (last actual as the forecast)
# Alignment (consistent with visualization/scripts/precompute/accuracy.py):
#   row-r information predicts row r+1. Online semantics: the controller's
#   current observation z_τ is the actual net demand at row r = τ + 96
#   (see audit: decision moment = row t+96).
# Outputs:
#   controller_forecast.json  — per-site RMSE/MAE/bias/R² for the three forecasts
#   forecast_curves.json      — 70 sites × 192-step window (actual/ar1/se)
# ============================================================================
using JLD2, CSV, DataFrames, Statistics, JSON

const ROOT = "/Users/kevin/emsx-experiment"
const VF_DIR = joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20", "value_functions")
const TEST_DIR = joinpath(ROOT, "dataset", "test")
const OUT_DIR = "/tmp/emsx_forecast"
mkpath(OUT_DIR)

const H = 672          # alpha/beta length (7 days × 96)
const WINDOW = 192     # curve window: 2 days of 15-min steps

function site_net(df, r::Int)
    return df.actual_consumption[r] - df.actual_pv[r]
end

sites = Dict{String,Any}[]
curves = Dict{String,Any}[]
missing_vf = Int[]

for sid in 1:70
    vf_path = joinpath(VF_DIR, "$(sid).jld2")
    if !isfile(vf_path)
        push!(missing_vf, sid)
        continue
    end
    payload = JLD2.load(vf_path)
    alpha = Vector{Float64}(payload["alpha"])
    beta  = Vector{Float64}(payload["beta"])
    length(alpha) == H || error("alpha length $(length(alpha)) != $H for site $sid")

    df = CSV.read(joinpath(TEST_DIR, "$(sid).csv.gz"), DataFrame)

    errs_ar1 = Float64[]
    errs_se  = Float64[]
    errs_pers = Float64[]
    acts = Float64[]

    # first period (sorted by period_id) for the curve window
    first_period = true

    for g in groupby(df, :period_id)
        rows = g
        n = nrow(rows)
        tmax = min(H - 1, n - 97)          # need rows r=τ+96 and r+1
        tmax > 0 || continue
        for τ in 1:tmax
            r = τ + 96
            z_cur = site_net(rows, r)
            z_tgt = site_net(rows, r + 1)
            push!(errs_ar1, alpha[τ] * z_cur + beta[τ] - z_tgt)
            push!(errs_se,  (rows.load_00[r] - rows.pv_00[r]) - z_tgt)
            push!(errs_pers, z_cur - z_tgt)
            push!(acts, z_tgt)
        end
        if first_period
            first_period = false
            w = min(WINDOW, tmax)
            a = Float64[]
            b = Float64[]
            c = Float64[]
            for τ in 1:w
                r = τ + 96
                push!(a, site_net(rows, r + 1))
                push!(b, alpha[τ] * site_net(rows, r) + beta[τ])
                push!(c, rows.load_00[r] - rows.pv_00[r])
            end
            push!(curves, Dict("site" => sid, "actual" => round.(a, digits=3),
                               "ar1" => round.(b, digits=3), "se" => round.(c, digits=3)))
        end
    end

    n = length(acts)
    n == 0 && (println("no samples site $sid"); continue)
    as = Float64.(acts)
    mean_a = sum(as) / n
    sst = sum((as .- mean_a) .^ 2)
    function summarize(e)
        mae = sum(abs.(e)) / n
        bias = sum(e) / n
        rmse = sqrt(sum(e .^ 2) / n)
        r2 = sst > 0 ? 1.0 - sum(e .^ 2) / sst : NaN
        return Dict("rmse" => round(rmse; digits=4), "mae" => round(mae; digits=4),
                    "bias" => round(bias; digits=4), "r2" => round(r2; digits=4))
    end
    push!(sites, Dict("site" => sid, "n" => n,
                      "ar1" => summarize(errs_ar1),
                      "se"  => summarize(errs_se),
                      "persist" => summarize(errs_pers)))
end

meta = Dict("track" => "test",
            "horizon_steps" => 1,
            "aligned" => "row r info -> row r+1 actual; AR(1) tau = period-internal step (online semantics); SE uses row r's load_00-pv_00",
            "missing_value_functions" => missing_vf)

open(joinpath(OUT_DIR, "controller_forecast.json"), "w") do io
    JSON.print(io, Dict("meta" => meta, "sites" => sites))
end
open(joinpath(OUT_DIR, "forecast_curves.json"), "w") do io
    JSON.print(io, Dict("window_steps" => WINDOW, "sites" => curves))
end

println("controller_forecast: $(length(sites)) sites, missing VF: $(missing_vf)")
for sid in (62, 33, 59, 9, 3)
    row = findfirst(x -> x["site"] == sid, sites)
    row === nothing && continue
    s = sites[row]
    ar1_r2 = s["ar1"]["r2"]; ar1_rmse = s["ar1"]["rmse"]
    se_r2 = s["se"]["r2"];   se_rmse = s["se"]["rmse"]
    pe_rmse = s["persist"]["rmse"]
    println("  site $sid  AR1 r2=$ar1_r2 rmse=$ar1_rmse | SE r2=$se_r2 rmse=$se_rmse | PERS rmse=$pe_rmse")
end
