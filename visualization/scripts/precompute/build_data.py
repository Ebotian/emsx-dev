#!/usr/bin/env python3
"""Build the controller-parallel endpoint & per-site data (stage 3).

8 controllers: Dummy / MPC / OLFC-10 / SDP / SDP-AR(1) / S_AR / R_P / R_FE96
Sources:
  - MPC, OLFC: Mac re-run JSONs (physical LP scoring inside).
  - SDP: run_sdp_70.sh raw costs (scored here against LP oracle).
  - SDP-AR(1): same implementation as S_AR (our runner IS the SDP-AR(1)
    method with periodic-VI calibration); labelled explicitly.
  - S_AR / R_P / R_FE96: existing score.jld2 (dummy from scores_full,
    LP upper from physical_lp_oracle).
  - Dummy: control=0 cost = scores_full.dummy_per.
"""
import json, os, sys
import numpy as np

ROOT = os.environ.get("EMSX_DATA_ROOT", "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research")
PUB = os.path.join(os.path.dirname(__file__), "..", "..", "public", "data")

def load_refs():
    lp = {}
    with open("/tmp/physical_lp_oracle.csv") as f:
        import csv
        for r in csv.DictReader(f):
            lp[int(r["site"])] = float(r["lp_upper"])
    du = {}
    with open(os.path.join(ROOT, "results_sdp/dp_upper_bound_v1/scores_full.csv")) as f:
        import csv
        for r in csv.DictReader(f):
            du[int(r["site"])] = float(r["dummy_per"])
    return lp, du

def load_jld2_costs(path):
    # site -> mean period cost from a runner score.jld2
    import jld2py
    raise NotImplementedError("use julia to dump costs; see build_data.jl")

def main():
    lp, du = load_refs()
    # MPC / OLFC from Mac
    mpc = json.load(open("/tmp/mpc_results.json"))["sites"]
    olfc = json.load(open("/tmp/olfc_results.json"))["sites"]
    # SDP raw costs (local run)
    sdp = json.load(open(os.path.join(PUB, "paper_sdp_raw.json")))
    # S_AR / R_P / R_FE96 per-site costs from TSV dumps
    def read_tsv(cid):
        out = {}
        for line in open(os.path.join(PUB, f"ours_{cid}.tsv")):
            parts = line.split("\t")
            if len(parts) == 2:
                out[parts[0]] = {"cost": float(parts[1])}
        return out
    ours = {cid: read_tsv(cid) for cid in ("S_AR", "R_P", "R_FE96")}

    endpoints = {}
    per_site = {}
    for s in range(1, 71):
        d = du[s]; u = lp[s]
        row = {}
        def add(cid, cost, paper=None):
            sc = (d - cost) / (d - u) if (d - u) != 0 else 0.0
            row[cid] = {"cost": round(cost, 4), "score": round(sc, 6), "dummy": d, "lp": u, "paperScore": paper}
            per_site.setdefault(cid, {})[str(s)] = {"cost": round(cost, 4), "score": round(sc, 6)}
        add("Dummy", d)
        add("MPC", mpc[str(s)]["cost"], paper=0.487)
        add("OLFC-10", olfc[str(s)]["cost"], paper=0.513)
        add("SDP", sdp[str(s)], paper=0.691)
        add("SDP-AR(1)", ours["S_AR"][str(s)]["cost"], paper=0.794)
        add("S_AR", ours["S_AR"][str(s)]["cost"])
        add("R_P", ours["R_P"][str(s)]["cost"])
        add("R_FE96", ours["R_FE96"][str(s)]["cost"])
        endpoints[str(s)] = row
    # aggregate means
    def mean_of(cid, key):
        return round(sum(endpoints[str(s)][cid][key] for s in range(1, 71)) / 70, 4)
    summary = {cid: {"score": mean_of(cid, "score"), "cost": mean_of(cid, "cost"),
                     "paperScore": endpoints["1"][cid].get("paperScore")} for cid in endpoints["1"]}
    json.dump(summary, open(os.path.join(PUB, "endpoints.json"), "w"), indent=1)
    json.dump(per_site, open(os.path.join(PUB, "per_site.json"), "w"), indent=1)
    print("endpoints.json + per_site.json written")
    for cid, v in summary.items():
        print(f"  {cid:10s} score={v['score']:.4f} cost={v['cost']:.1f} paper={v.get('paperScore')}")

if __name__ == "__main__":
    main()
