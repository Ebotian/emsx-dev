#!/usr/bin/env python3
"""Paper OLFC controller re-run under the continuous-SOC convention.

OLFC (Open-Loop Feedback Control): at each decision step t, solve a
multistage stochastic open-loop LP over N scenarios sharing one control
sequence (u_k shared; SOC and cost split by scenario), take the first
action, re-solve at t+1 (feedback).

Scenario generation: scenario j = day-ahead forecast net demand
(load_{96-k} at row t+1, reversed) + epsilon_j, epsilon_j ~ N(0, sigma),
sigma = per-horizon persistence-residual std from the site's training data
(honest simplification; the paper does not disclose its scenario
generator). Fixed RNG seed for determinism.

Documented simplifications: horizon H=24, scenarios N=10 (paper does not
state its OLFC H/N); scipy HiGHS replaces CPLEX.
"""
import gzip, csv, os, sys
import numpy as np
from scipy.optimize import linprog

ROOT = os.environ.get("EMSX_DATA_ROOT", "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research")
def _p(*parts):
    cand = os.path.join(ROOT, *parts)
    return cand if os.path.exists(cand) else os.path.join(ROOT, parts[-1])
TEST = _p("dataset", "test")
if not os.path.isdir(TEST):
    TEST = os.path.join(ROOT, "test")

H = int(os.environ.get("OLFC_H", "24"))
N = int(os.environ.get("OLFC_N", "10"))
SIGMA_DEFAULT = 5.0

def load_battery(sid):
    with open(_p("dataset", "metadata.csv")) as f:
        r = next(x for x in csv.DictReader(f) if int(x["site_id"]) == sid)
    return (float(r["capacity"]), float(r["power"]),
            float(r["charge_efficiency"]), float(r["discharge_efficiency"]))

def load_prices():
    with open(_p("EMSx.jl", "metadata", "edf_prices.csv")) as f:
        r = list(csv.DictReader(f))
    return (np.array([float(x["buy"]) for x in r]), np.array([float(x["sell"]) for x in r]))

def persistence_resid_std(sid, train_path):
    with gzip.open(train_path, "rt") as f:
        rows = list(csv.DictReader(f))
    z = np.array([float(r["actual_consumption"]) - float(r["actual_pv"]) for r in rows])
    n = len(z); nw = n // 672
    if nw < 2:
        return SIGMA_DEFAULT
    zw = z[:nw * 672].reshape(672, nw)
    return float(np.std(zw[1:] - zw[:-1]))

def olfc_action(battery, buy, sell, soc0, forecast_net, t, sigma):
    cap, P, ec, ed = battery
    Pdt = P * 0.25
    s = Pdt / cap
    zbase = forecast_net[::-1][:H]
    rng = np.random.default_rng(0)
    eps = rng.normal(0.0, sigma, size=(N, H))
    pb = np.array([buy[(t - 1 + k) % 672] for k in range(H)])
    ps = np.array([sell[(t - 1 + k) % 672] for k in range(H)])
    # vars: u, up, ud (1..H, shared) + per (k, sc): soc_next, pos, neg
    nu = 3 * H
    nsc = H * N
    def iu(k): return k - 1
    def iup(k): return H + k - 1
    def iud(k): return 2 * H + k - 1
    def isoc(k, sc): return nu + (k - 2) * N + sc          # k=2..H+1
    def ipos(k, sc): return nu + H * N + (k - 1) * N + sc
    def ineg(k, sc): return nu + 2 * H * N + (k - 1) * N + sc
    nv = nu + 3 * H * N
    c = np.zeros(nv)
    for k in range(1, H + 1):
        for sc in range(N):
            c[ipos(k, sc)] = pb[k - 1] / N
            c[ineg(k, sc)] = -ps[k - 1] / N
    A = []; b = []; bounds = [(None, None)] * nv
    for k in range(1, H + 1):
        bounds[iu(k)] = (-1, 1); bounds[iup(k)] = (0, None); bounds[iud(k)] = (0, None)
        row = np.zeros(nv); row[iup(k)] = 1; row[iud(k)] = -1; row[iu(k)] = -1
        A.append(row); b.append(0.0)
        for sc in range(N):
            bounds[isoc(k + 1, sc)] = (0, 1)
            bounds[ipos(k, sc)] = (0, None); bounds[ineg(k, sc)] = (0, None)
            z = zbase[k - 1] + eps[sc, k - 1]
            row = np.zeros(nv); row[ipos(k, sc)] = 1; row[ineg(k, sc)] = -1; row[iu(k)] = -Pdt
            A.append(row); b.append(z)
            row = np.zeros(nv); row[isoc(k + 1, sc)] = 1
            if k > 1: row[isoc(k, sc)] = -1
            row[iup(k)] = -ec * s
            row[iud(k)] = +s / ed
            A.append(row); b.append(0.0)
    Aeq = np.array(A); beq = np.array(b)
    # k=1 dynamics: soc_2 - ec*s*up_1 + s/ed*ud_1 = soc0
    beq[1 + N * 0 + 0] = soc0
    res = linprog(c, A_eq=Aeq, b_eq=beq, bounds=bounds, method="highs")
    if res.status != 0:
        raise RuntimeError(f"OLFC LP failed at t={t}: {res.message}")
    return float(res.x[iu(1)])

def simulate_olfc(sid, buy, sell, train_path, progress_every=None):
    battery = load_battery(sid)
    cap, P, ec, ed = battery
    Pdt = P * 0.25
    sigma = persistence_resid_std(sid, train_path) if train_path and os.path.exists(train_path) else SIGMA_DEFAULT
    with gzip.open(os.path.join(TEST, f"{sid}.csv.gz"), "rt") as f:
        rows = list(csv.DictReader(f))
    per = [int(r["period_id"]) for r in rows]
    load = np.array([float(r["actual_consumption"]) for r in rows])
    pv = np.array([float(r["actual_pv"]) for r in rows])
    fnet = np.array([[float(r[f"load_{i:02d}"]) for i in range(96)] for r in rows]) - \
           np.array([[float(r[f"pv_{i:02d}"]) for i in range(96)] for r in rows])
    uq = sorted(set(per))
    soc = 0.0; total = 0.0
    for p in uq:
        idx = [i for i, v in enumerate(per) if v == p]
        lo = idx[0]; h = len(idx) - 96
        for k in range(h):
            t = lo + k + 1
            settle = lo + min(k + 97, len(idx) - 1)
            zt = load[settle] - pv[settle]
            u = olfc_action(battery, buy, sell, soc, fnet[t], t, sigma)
            imported = u * Pdt + zt
            total += buy[(t - 1) % 672] * max(0.0, imported) - sell[(t - 1) % 672] * max(0.0, -imported)
            soc = min(1.0, max(0.0, soc + (ec * max(0.0, u) - max(0.0, -u) / ed) * Pdt / cap))
        if progress_every and p % progress_every == 0:
            print(f"  site {sid} period {p} done, total={total:.1f}", flush=True)
    return total / len(uq)

if __name__ == "__main__":
    sid = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    buy, sell = load_prices()
    train = _p("dataset", "train", f"{sid}.csv.gz")
    if not os.path.exists(train):
        train = os.path.join(os.path.dirname(TEST), "train", f"{sid}.csv.gz")
    cost = simulate_olfc(sid, buy, sell, train, progress_every=5)
    print(f"site {sid}: OLFC(H={H},N={N}) mean period cost = {cost:.2f}")
