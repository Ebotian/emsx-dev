#!/usr/bin/env julia
# ============================================================================
# Benefit-vs-accuracy curve (λ sweep) on the 70 EMSx sites.
# Decision forecast: ẑ(λ) = (1-λ)·AR(1) + λ·z_actual(t+1), λ ∈ [0,1].
#   λ=0 → current S_AR decision;  λ=1 → one-step perfect-foresight oracle.
# Traces the dispatch gain vs the price-weighted decision-forecast error
# (wmae_dec) to test concavity / saturation at the anticipative upper bound.
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
LAMBDAS = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]

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

# results[λ] -> vector of per-site (gain, wmae_dec)
res = Dict{Float64,Vector{Tuple{Float64,Float64}}}(lam => Tuple{Float64,Float64}[] for lam in LAMBDAS)

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

    for lam in LAMBDAS
        soc = 0.0; cost = 0.0; cost_d = 0.0; wmae = 0.0; nd = 0
        for g in groupby(df, :period_id)
            rows = g; n = nrow(rows); h = n - 96
            for t in 1:h
                r_tgt = min(t + 97, n)
                z_cur = rows.actual_consumption[t+96] - rows.actual_pv[t+96]
                z_tgt = rows.actual_consumption[r_tgt] - rows.actual_pv[r_tgt]
                za = clamp(alpha[t] * z_cur + beta[t], zmin, zmax)
                zhat = clamp((1.0 - lam) * za + lam * clamp(z_tgt, zmin, zmax), zmin, zmax)
                b = buy[t]; s = sell[t]
                wmae += b * abs(zhat - z_tgt); nd += 1
                u = decide(u_grid, zhat, soc, itps[t], b, s, E, scale)
                soc_n = soc + (eta_c * max(0.0, u) - max(0.0, -u) / eta_d) * scale
                soc = max(0.0, min(1.0, soc_n))
                cost += b * max(0.0, z_tgt + u * E) - s * max(0.0, -(z_tgt + u * E))
                cost_d += b * max(0.0, z_tgt) - s * max(0.0, -z_tgt)   # dummy u=0
            end
        end
        push!(res[lam], (cost_d - cost, wmae / nd))
    end
end

# aggregate + print the curve
println("=== 收益-精度曲线（70 站点均值） ===")
println("λ     gain(均值)      wmae_dec(均值)   边际gain")
rows_out = [(lam, mean(x[1] for x in res[lam]), mean(x[2] for x in res[lam])) for lam in LAMBDAS]
for i in eachindex(rows_out)
    lam, g, w = rows_out[i]
    mg = i == 1 ? NaN : g - rows_out[i-1][2]
    println(rpad(string(lam), 5), lpad(round(Int, g), 12), lpad(round(w, digits=1), 14), lpad(round(Int, mg), 10))
end
out = Dict(string(lam) => [Dict("gain" => x[1], "wmae" => x[2]) for x in res[lam]] for lam in LAMBDAS)
open("/tmp/probe_lambda.json", "w") do io
    JSON.print(io, out, 2)
end
println("saved /tmp/probe_lambda.json")
