#!/usr/bin/env julia
# ============================================================================
# 2D benefit surface: price ratio (peak x mult) x forecast accuracy (lambda).
#   ẑ(λ) = (1-λ)·AR(1) + λ·z_actual(t+1); prices rescaled by mult on peak steps.
#   z = dispatch gain (and efficiency = gain / oracle(λ=1) at each mult).
# Parallelized over sites with Threads.@threads (run with julia -t N).
# Per-site value-function interpolators are built ONCE and reused across the
# 42 (mult, lambda) combos. Output: /tmp/probe_surface.json
# ============================================================================
using JLD2, CSV, DataFrames, Statistics, JSON, Interpolations, Base.Threads

const ROOT = "/Users/kevin/emsx-experiment"
const VF_DIR = joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20", "value_functions")
const TEST_DIR = joinpath(ROOT, "dataset", "test")
const PRICE_CSV = joinpath(ROOT, "EMSx.jl", "metadata", "edf_prices.csv")
const META_CSV = joinpath(ROOT, "dataset", "metadata.csv")
prices = CSV.read(PRICE_CSV, DataFrame)
buy0 = Float64.(prices.buy); sell0 = Float64.(prices.sell)
const PEAK0 = 0.17
const IS_PEAK = buy0 .>= PEAK0
meta = CSV.read(META_CSV, DataFrame)
pow_by = Dict(Int(m.site_id) => m.power for m in eachrow(meta))
cap_by = Dict(Int(m.site_id) => m.capacity for m in eachrow(meta))
eta_c, eta_d = 0.95, 0.95
const DX = 0.1; const NZ = 20; const DU = 0.1; const DT = 0.25
soc_axis = 0.0:DX:1.0
const MULTS = [1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 40.0]
const LAMBDAS = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
const NCOMB = length(MULTS) * length(LAMBDAS)

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

# per-site results: combos -> (gain, wmae). Thread-safe writes (each site own slot).
site_results = Vector{Vector{Tuple{Float64,Float64}}}(undef, 70)   # site -> [combo] -> (gain, wmae)

@threads for sid in 1:70
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
    per_site = Vector{Tuple{Float64,Float64}}(undef, NCOMB)
    ci = 0
    for mult in MULTS, lam in LAMBDAS
        ci += 1
        buy = [IS_PEAK[i] ? buy0[i] * mult : buy0[i] for i in eachindex(buy0)]
        sell = [IS_PEAK[i] ? sell0[i] * mult : sell0[i] for i in eachindex(sell0)]
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
                cost_d += b * max(0.0, z_tgt) - s * max(0.0, -z_tgt)
            end
        end
        per_site[ci] = (cost_d - cost, wmae / nd)
    end
    site_results[sid] = per_site
end

# aggregate by combo
combos = [(m, l) for m in MULTS for l in LAMBDAS]
agg = Dict{String,Any}()
for (ci, (m, l)) in enumerate(combos)
    gains = [site_results[s][ci][1] for s in 1:70]
    wmaes = [site_results[s][ci][2] for s in 1:70]
    agg["$(m)_$(l)"] = Dict("mult" => m, "lambda" => l,
        "gain" => mean(gains), "wmae" => mean(wmaes),
        "gain_by_site" => gains, "wmae_by_site" => wmaes)
end
open("/tmp/probe_surface.json", "w") do io
    JSON.print(io, agg, 2)
end
println("saved /tmp/probe_surface.json (threads=", Threads.nthreads(), ")")
