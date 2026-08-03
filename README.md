# EMSx Battery Control — Benchmark Audit & Online Rollout

This repository contains a research project built around the **EMSx**
microgrid energy-management benchmark: a critical audit of the benchmark's
evaluation semantics, online stochastic controllers evaluated under a
physically consistent metric, and an interactive static website
visualizing every result.

## The original benchmark

- **Paper** — *EMSx: a numerical benchmark for energy management systems*,
  A. Le Franc et al.,
  [arXiv:2001.00450](https://arxiv.org/abs/2001.00450),
  *Energy Systems* (Springer, 2021).
- **Software** — [EMSx.jl](https://github.com/adrien-le-franc/EMSx.jl),
  a Julia package for simulating grid-connected microgrids (PV + battery).
- **Data** — Schneider Electric microgrids: 70 sites, ~2 years of 15-minute
  net-demand observations and day-ahead forecasts
  ([Zenodo](https://zenodo.org/record/5510400)).
- **Paper baselines** — Model Predictive Control (MPC), Open-Loop Feedback
  Control (OLFC), and Stochastic Dynamic Programming (SDP); the best paper
  controller is **SDP-AR(1)**, which models net demand as an AR(1) process.

The local checkout of `EMSx.jl` is pinned in `EMSx.jl/` and locked in the
Julia `Manifest.toml`; the dataset is downloaded separately (gitignored).

## What this project does

### 1. Audit of the benchmark evaluation

- **Energy-conservation violation.** The benchmark's stage cost credits
  discharge energy from an *empty* battery while the state of charge is only
  clamped to zero. A controller can harvest free energy by dispatching
  discharge at SOC = 0 — the original near-perfect scores (e.g. 0.9973) are
  dominated by this exploit, not by control quality.
- **Information timing.** A timestamp-level reconstruction of the simulator
  shows the decision moment is row *t*+96 of the data window: the actual
  net demand at row *t*+96 is the *current* observation, not future
  leakage. The official `Information` interface exposes the day-ahead
  forecast from row *t*+1. Temporal causality, interface admissibility, and
  benchmark protocol are separated explicitly.
- **Physical oracle.** An independent linear program with strict SOC bounds
  serves as the perfect-prediction oracle under physical dynamics; its
  actions replay through the simulator to 1e-11 consistency.

### 2. Controllers

| Controller | Description |
|---|---|
| `S_AR` | original stochastic SDP-AR(1) selector + physical action filter |
| `R_P` | actual-state persistence rollout with physical action filter |
| `R_FE96` | horizon-96 forecast-error multi-scenario rollout, CVaR-regularized Bellman selector |
| MLP clone | per-site behavior clone of the physical oracle (recorded negative result) |

### 3. Results — physical track (70 sites, mean per-site normalized score)

| Controller | Score |
|---|---|
| `S_AR` (best baseline) | **0.7677** |
| `R_P` | 0.7442 (11/70 sites above baseline) |
| `R_FE96` | 0.5794 |
| MLP clone | 0.5731 |

The original SDP-AR(1) baseline remains the strongest controller under the
physical evaluation; the persistence rollout `R_P` is the closest proposed
controller and does not beat it on average (mean cost 2243.4 vs 2235.7).
The forecast-error and behavior-clone routes are recorded negative results.

### 4. Formal verification

`leanproof/` contains Lean 4 proofs of selected algebraic properties of the
finite-benchmark score and resampling summaries (score range bounds,
finite-resampling inequalities).

### 5. Interactive visualization

`visualization/` is a static site (Astro + Svelte 5 + TypeScript +
ECharts) with 9 pages covering forecast data, dispatch curves, the exploit
audit, information timing, the dual-track leaderboard, per-site and
per-controller process differences, and sensitivity. All data is prepared
in parallel per controller; benchmark-track and physical-track results are
labeled separately throughout. See `visualization/README.md`.

## Repository layout

| Path | Contents |
|---|---|
| `sdp_*.jl` | Julia drivers: SDP-AR(1) calibration/simulation/evaluation, rollouts, parameter sweeps |
| `sweep_parallel.jl`, `run_sweep.sh` | parameter sweep driver + launcher |
| `src/` | shared modules: environment identity, provenance, run contract (leased, SHA-256-guarded runs) |
| `scripts/` | Julia environment bootstrap, locked runner, baseline capture |
| `configs/` | locked experiment configuration (`wdwe2_k20.toml`) |
| `baselines/` | input/provenance manifests of the reproduced baseline |
| `audit/` | preexisting-state audit records |
| `test/` | Julia test suite |
| `leanproof/` | Lean 4 formalization |
| `typst_conclusion/` | the audit report (source + PDF) |
| `visualization/` | interactive results site |
| `docs/` | design specs and plans |
| `paper/` | paper sources and figures |

## Requirements

- Julia **1.12.6** (pinned in `Project.toml` / `Manifest.toml`)
- local clone of EMSx.jl at `EMSx.jl/` (already present in the repo tree)
- the EMSx dataset in `dataset/` (train/test + metadata, ~6 GB, **not** in
  this repository — download from Zenodo via `EMSx.download_sites_data`)

## How to run

### Julia environment

```sh
./scripts/bootstrap_julia_env.sh
```

Validates the Julia version, the manifest lock, and the local `EMSx.jl`
path, then installs dependencies into the project-local depot
(`.julia-depot/`).

### Tests

```sh
./scripts/julia_locked.sh test/runtests.jl
```

### Locked baseline reproduction (70 sites)

```sh
PHASE=calibrate RUN_ID=local ./scripts/julia_locked.sh sdp_ar1_wdwe2.jl
PHASE=simulate  RUN_ID=local ./scripts/julia_locked.sh sdp_ar1_wdwe2.jl
PHASE=evaluate  RUN_ID=local ./scripts/julia_locked.sh sdp_ar1_wdwe2.jl
```

Configuration comes from `configs/wdwe2_k20.toml` (override with
`EXPERIMENT_CONFIG`). Each run is leased, fingerprinted (SHA-256), and
published atomically by `src/RunContract.jl`; the expected mean score is
0.7676755785921663.

### Parameter sweep

```sh
./run_sweep.sh   # 6 discretization variants of SDP-AR(1), run sequentially
```

### Visualization site

```sh
cd visualization
pnpm install
pnpm dev       # dev server at http://localhost:4321
pnpm build     # static output to dist/
pnpm preview   # serve the built site
```

### Audit report

```sh
typst compile typst_conclusion/emsx_verified_rollout.typ
```

## License

Apache-2.0. The EMSx dataset and the `EMSx.jl` package are third-party; the
dataset is downloaded separately and is not part of this repository.
