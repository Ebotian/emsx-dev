#!/usr/bin/env python3
"""Run paper MPC on all 70 sites (parallel), continuous-SOC convention,
score with the physical LP oracle. Usage:
  EMSX_DATA_ROOT=<dir with test/ metadata.csv edf_prices.csv physical_lp_oracle.csv scores_full.csv> \
  python paper_mpc_70.py [--workers N] [--out out.json]
Output: JSON {site: {cost, score, dummy, lp}} plus process trajectory for a
representative week (site 1, first period) under --traj.
"""
import argparse, json, os, sys
import numpy as np
from multiprocessing import Pool
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paper_mpc import load_battery, load_prices, simulate_mpc, mpc_action
import gzip, csv

ROOT = os.environ.get("EMSX_DATA_ROOT", "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research")
TEST = os.path.join(ROOT, "dataset", "test") if os.path.isdir(os.path.join(ROOT, "dataset", "test")) else os.path.join(ROOT, "test")

def load_refs():
    lp = {}
    with open(os.path.join(ROOT, "physical_lp_oracle.csv")) as f:
        for r in csv.DictReader(f):
            lp[int(r["site"])] = float(r["lp_upper"])
    du = {}
    with open(os.path.join(ROOT, "scores_full.csv")) as f:
        for r in csv.DictReader(f):
            du[int(r["site"])] = float(r["dummy_per"])
    return lp, du

def site_job(args):
    sid, buy, sell = args
    cost, nsteps = simulate_mpc(sid, buy, sell)
    return sid, cost, nsteps

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "public", "data", "paper_mpc.json"))
    args = ap.parse_args()
    buy, sell = load_prices()
    lp, du = load_refs()
    with Pool(args.workers) as pool:
        results = list(pool.imap_unordered(site_job, [(s, buy, sell) for s in range(1, 71)]))
    data = {}
    for sid, cost, nsteps in results:
        score = (du[sid] - cost) / (du[sid] - lp[sid])
        data[str(sid)] = {"cost": round(cost, 4), "score": round(score, 6),
                          "dummy": du[sid], "lp": lp[sid], "steps": nsteps}
        print(f"site {sid}: cost={cost:.2f} score={score:.4f}", flush=True)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({"controller": "MPC", "convention": "continuous-soc",
                   "method": "paper MPC (H=96 deterministic lookahead LP, scipy HiGHS)",
                   "sites": data}, f, indent=1)
    scores = [v["score"] for v in data.values()]
    print(f"MPC 70-site mean physical score = {np.mean(scores):.4f}")

if __name__ == "__main__":
    main()
