#!/usr/bin/env python3
"""Run paper OLFC on all 70 sites (parallel), continuous-SOC convention,
physical LP scoring. Usage: EMSX_DATA_ROOT=<dir> python paper_olfc_70.py [--out out.json]"""
import argparse, json, os, sys
import numpy as np
from multiprocessing import Pool
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paper_olfc import load_battery, load_prices, simulate_olfc
import csv

ROOT = os.environ.get("EMSX_DATA_ROOT", "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research")
def _p(*parts):
    cand = os.path.join(ROOT, *parts)
    return cand if os.path.exists(cand) else os.path.join(ROOT, parts[-1])

def load_refs():
    lp = {}
    with open(_p("physical_lp_oracle.csv")) as f:
        for r in csv.DictReader(f):
            lp[int(r["site"])] = float(r["lp_upper"])
    du = {}
    with open(_p("scores_full.csv")) as f:
        for r in csv.DictReader(f):
            du[int(r["site"])] = float(r["dummy_per"])
    return lp, du

def site_job(args):
    sid, buy, sell, train_path = args
    cost = simulate_olfc(sid, buy, sell, train_path)
    return sid, cost

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "public", "data", "paper_olfc.json"))
    args = ap.parse_args()
    buy, sell = load_prices()
    lp, du = load_refs()
    train_root = _p("dataset", "train")
    jobs = [(s, buy, sell, os.path.join(train_root, f"{s}.csv.gz") if os.path.isdir(train_root) else None)
            for s in range(1, 71)]
    with Pool(args.workers) as pool:
        results = list(pool.imap_unordered(site_job, jobs))
    data = {}
    for sid, cost in results:
        score = (du[sid] - cost) / (du[sid] - lp[sid])
        data[str(sid)] = {"cost": round(cost, 4), "score": round(score, 6),
                          "dummy": du[sid], "lp": lp[sid]}
        print(f"site {sid}: cost={cost:.2f} score={score:.4f}", flush=True)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({"controller": "OLFC-10", "convention": "continuous-soc",
                   "method": "paper OLFC (multi-scenario open-loop LP, H=24, N=10, "
                             "Gaussian scenario noise, scipy HiGHS; documented simplification)",
                   "sites": data}, f, indent=1)
    scores = [v["score"] for v in data.values()]
    print(f"OLFC 70-site mean physical score = {np.mean(scores):.4f}")

if __name__ == "__main__":
    main()
