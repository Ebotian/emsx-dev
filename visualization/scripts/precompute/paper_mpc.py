#!/usr/bin/env python3
"""Paper MPC controller re-run under the physical (continuous-SOC) convention.

MPC: at each decision step t, solve a deterministic H-step lookahead LP
with the day-ahead forecast vector as the disturbance sequence, take the
first action. Forecast alignment: row t+1's load_j predicts row t+1+j+1;
the settlement row is t+97 (= t+1+96), so internal step k uses load_{96-k}
(k=1 -> load_95, k=96 -> load_00), i.e. the forecast vector reversed.
Physics: SOC in [0,1], u in [-1,1], charge/discharge efficiencies.

Emulates the paper MPC (H=96) with scipy HiGHS instead of CPLEX.
"""
import gzip, csv, os, sys
import numpy as np
from scipy.optimize import linprog

ROOT = os.environ.get("EMSX_DATA_ROOT", "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research")
def _p(*parts):
    cand = os.path.join(ROOT, *parts)
    if os.path.exists(cand):
        return cand
    return os.path.join(ROOT, parts[-1])  # flat layout (e.g. /tmp/emsxdata/metadata.csv)
TEST = _p("dataset", "test")
if not os.path.isdir(TEST):
    TEST = os.path.join(ROOT, "test")
H = 96  # lookahead horizon (paper)

def load_battery(sid):
    with open(_p("dataset", "metadata.csv")) as f:
        r = next(x for x in csv.DictReader(f) if int(x["site_id"]) == sid)
    return (float(r["capacity"]), float(r["power"]),
            float(r["charge_efficiency"]), float(r["discharge_efficiency"]))

def load_prices():
    with open(_p("EMSx.jl", "metadata", "edf_prices.csv")) as f:
        r = list(csv.DictReader(f))
    return (np.array([float(x["buy"]) for x in r]), np.array([float(x["sell"]) for x in r]))

def mpc_action(battery, buy, sell, soc0, forecast_net, t):
    """forecast_net: 96-vector, index j = load_j at row t+1 (predicts row t+1+j+1).
    Returns u_1 (first action)."""
    cap, P, ec, ed = battery
    Pdt = P * 0.25
    s = Pdt / cap
    # internal step k (1..H): demand z_k = forecast_net[96-k]
    z = forecast_net[::-1][:H]  # z[0] = load_95 (settlement), ..., z[95] = load_00
    # prices for internal steps: buy[t], buy[t+1], ... (wrap within 672)
    pb = np.array([buy[(t - 1 + k) % 672] for k in range(H)])
    ps = np.array([sell[(t - 1 + k) % 672] for k in range(H)])
    # vars per step: u, up, ud, soc_next, pos, neg
    nv = 6 * H
    def iu(k): return k - 1
    def iup(k): return H + k - 1
    def iud(k): return 2 * H + k - 1
    def isoc(k): return 3 * H + (k - 2)  # soc_2..soc_{H+1}
    def ipos(k): return 4 * H + k - 1
    def ineg(k): return 5 * H + k - 1
    c = np.zeros(nv)
    for k in range(1, H + 1):
        c[ipos(k)] = pb[k - 1]
        c[ineg(k)] = -ps[k - 1]
    A = []; b = []; bounds = [(None, None)] * nv
    for k in range(1, H + 1):
        bounds[iu(k)] = (-1, 1); bounds[iup(k)] = (0, None); bounds[iud(k)] = (0, None)
        bounds[isoc(k + 1)] = (0, 1); bounds[ipos(k)] = (0, None); bounds[ineg(k)] = (0, None)
        row = np.zeros(nv); row[iup(k)] = 1; row[iud(k)] = -1; row[iu(k)] = -1
        A.append(row); b.append(0.0)
        row = np.zeros(nv); row[ipos(k)] = 1; row[ineg(k)] = -1; row[iu(k)] = -Pdt
        A.append(row); b.append(z[k - 1])
        row = np.zeros(nv); row[isoc(k + 1)] = 1
        if k > 1: row[isoc(k)] = -1
        row[iup(k)] = -ec * s; row[iud(k)] = +s / ed
        A.append(row); b.append(0.0)
    Aeq = np.array(A); beq = np.array(b)
    beq[2] = soc0  # k=1 dynamics: soc_2 - ... = soc0
    res = linprog(c, A_eq=Aeq, b_eq=beq, bounds=bounds, method="highs")
    if res.status != 0:
        raise RuntimeError(f"MPC LP failed at t={t}: {res.message}")
    return float(res.x[iu(1)])

def simulate_mpc(sid, buy, sell, progress_every=None):
    battery = load_battery(sid)
    cap, P, ec, ed = battery
    Pdt = P * 0.25
    with gzip.open(os.path.join(TEST, f"{sid}.csv.gz"), "rt") as f:
        rows = list(csv.DictReader(f))
    per = [int(r["period_id"]) for r in rows]
    n = len(rows)
    load = np.array([float(r["actual_consumption"]) for r in rows])
    pv = np.array([float(r["actual_pv"]) for r in rows])
    # forecast net demand: load_j - pv_j at each row
    fcols = [f"load_{i:02d}" for i in range(96)]
    fpcols = [f"pv_{i:02d}" for i in range(96)]
    fnet = np.array([[float(r[c]) for c in fcols] for r in rows]) - \
           np.array([[float(r[c]) for c in fpcols] for r in rows])
    uq = sorted(set(per))
    soc = 0.0
    total = 0.0
    nsteps = 0
    for p in uq:
        idx = [i for i, v in enumerate(per) if v == p]
        lo = idx[0]
        h = len(idx) - 96
        for k in range(h):  # internal step k (0-based), decision row = lo + k + 96
            t = lo + k + 1  # row t+1 (forecast origin)
            # settlement actual at row lo + k + 97 = min(t+96+1, ...)
            settle = lo + min(k + 97, len(idx) - 1)
            zt = load[settle] - pv[settle]
            u = mpc_action(battery, buy, sell, soc, fnet[t], t)
            imported = u * Pdt + zt
            total += buy[(t - 1) % 672] * max(0.0, imported) - sell[(t - 1) % 672] * max(0.0, -imported)
            soc = min(1.0, max(0.0, soc + (ec * max(0.0, u) - max(0.0, -u) / ed) * Pdt / cap))
            nsteps += 1
        if progress_every and p % progress_every == 0:
            print(f"  site {sid} period {p} done, total={total:.1f}", flush=True)
    return total / len(uq), nsteps

if __name__ == "__main__":
    buy, sell = load_prices()
    sid = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    cost, nsteps = simulate_mpc(sid, buy, sell, progress_every=5)
    print(f"site {sid}: MPC mean period cost = {cost:.2f}, steps = {nsteps}")
