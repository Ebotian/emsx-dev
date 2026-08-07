using JLD2, CSV, DataFrames, Statistics, Interpolations
const ROOT = "/Users/kevin/emsx-experiment"
const VF_DIR = joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20", "value_functions")
const TEST_DIR = joinpath(ROOT, "dataset", "test")
const PRICE_CSV = joinpath(ROOT, "EMSx.jl", "metadata", "edf_prices.csv")
const META_CSV = joinpath(ROOT, "dataset", "metadata.csv")
prices = CSV.read(PRICE_CSV, DataFrame)
buy0 = Float64.(prices.buy); sell0 = Float64.(prices.sell)
const PEAK0 = 0.17; const IS_PEAK = buy0 .>= PEAK0
meta = CSV.read(META_CSV, DataFrame)
pow_by = Dict(Int(m.site_id) => m.power for m in eachrow(meta))
cap_by = Dict(Int(m.site_id) => m.capacity for m in eachrow(meta))
eta_c, eta_d = 0.95, 0.95
const DX = 0.1; const NZ = 20; const DU = 0.1; const DT = 0.25
soc_axis = 0.0:DX:1.0
MULT = 40.0
buy = [IS_PEAK[i] ? buy0[i]*MULT : buy0[i] for i in eachindex(buy0)]
sell = [IS_PEAK[i] ? sell0[i]*MULT : sell0[i] for i in eachindex(sell0)]
function decide(u_grid, zhat, soc, itp, b, s, E, scale)
    best = Inf; bestu = 0.0
    for u in u_grid
        soc_n = soc + (eta_c*max(0.0,u) - max(0.0,-u)/eta_d)*scale
        (0.0 <= soc_n <= 1.0) || continue
        imp = zhat + u*E
        c = b*max(0.0, imp) - s*max(0.0, -imp) + itp(soc_n, zhat)
        if c < best; best = c; bestu = u; end
    end
    return bestu
end
function main()
ga = [0.0, 0.0, 0.0]   # ar1, perfect, se
ndiff_se = 0; ndiff_pf = 0; ntot = 0
for sid in 1:70
    df = CSV.read(joinpath(TEST_DIR, "$(sid).csv.gz"), DataFrame)
    p = JLD2.load(joinpath(VF_DIR, "$(sid).jld2"))
    alpha = Vector{Float64}(p["alpha"]); beta = Vector{Float64}(p["beta"])
    zmin, zmax = p["z_min"], p["z_max"]
    vf = p["value_function"].functions
    z_axis = range(zmin, zmax, length=NZ)
    itps = [linear_interpolation((soc_axis, z_axis), vf[t+1, :, :]; extrapolation_bc=Line()) for t in 1:672]
    E = pow_by[sid]*DT; scale = E/cap_by[sid]
    u_grid = -1.0:DU:1.0
    socs = [0.0, 0.0, 0.0]; costs = [0.0, 0.0, 0.0]
    for g in groupby(df, :period_id)
        rows = g; n = nrow(rows); h = n - 96
        for t in 1:h
            r_tgt = min(t+97, n)
            z_cur = rows.actual_consumption[t+96] - rows.actual_pv[t+96]
            z_tgt = rows.actual_consumption[r_tgt] - rows.actual_pv[r_tgt]
            za = clamp(alpha[t]*z_cur + beta[t], zmin, zmax)
            zs = clamp(Float64(rows.load_00[r_tgt] - rows.pv_00[r_tgt]), zmin, zmax)
            zpf = clamp(z_tgt, zmin, zmax)
            b = buy[t]; s = sell[t]
            us = [0.0, 0.0, 0.0]
            us[1] = decide(u_grid, za, socs[1], itps[t], b, s, E, scale)
            us[2] = decide(u_grid, zpf, socs[2], itps[t], b, s, E, scale)
            us[3] = decide(u_grid, zs, socs[3], itps[t], b, s, E, scale)
            abs(us[3]-us[1]) > 0 && (ndiff_se += 1)
            abs(us[2]-us[1]) > 0 && (ndiff_pf += 1)
            ntot += 1
            for i in 1:3
                soc_n = socs[i] + (eta_c*max(0.0,us[i]) - max(0.0,-us[i])/eta_d)*scale
                socs[i] = max(0.0, min(1.0, soc_n))
                costs[i] += b*max(0.0, z_tgt + us[i]*E) - s*max(0.0, -(z_tgt + us[i]*E))
            end
        end
    end
    for i in 1:3; ga[i] += costs[i]; end
end
for (i, nm) in enumerate(("ar1", "perfect", "se"))
    println("$nm 总成本: $(round(ga[i]; digits=1))")
end
println("决策差异: SE vs ar1: $ndiff_se/$ntot  perfect vs ar1: $ndiff_pf/$ntot")
end
main()
