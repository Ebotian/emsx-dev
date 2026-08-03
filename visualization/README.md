# EMSx Audit — Interactive Visualization

A static, interactive site presenting the EMSx benchmark audit and the
online-rollout results from the parent repository. Every chart corresponds
to a closed claim of the audit report (`../typst_conclusion/`); negative
results are shown as prominently as positive ones.

## Pages

| Route | Content |
|---|---|
| `index` | overview + research journey (score evolution with exploit/audit labels) |
| `01_data_forecast` | dataset structure, day-ahead forecast accuracy over horizons |
| `02_dispatch` | dispatch curves with controller switching, energy-balance annotation |
| `03_exploit` | energy-conservation violation audit (empty-battery discharge) |
| `04_timing` | decision timestamp and information structure timeline |
| `05_results` | dual-track leaderboard (official EMSx vs physical LP track) |
| `06_per_site` | per-site cost scatter, 70 sites |
| `07_process` | per-controller process trajectories (controller-parallel) |
| `08_sensitivity` | persistence/AR prediction-quality sensitivity |

Benchmark-track and physical-track results are kept in separate labeled
views; controller selectors run through pages 02/05/06/07.

## Stack

- **Astro 5** (static output) + **Svelte 5** (chart/interaction components)
  + **TypeScript** + **Vite** + **pnpm** + **ECharts**
- Helvetica-style minimal design tokens (near-black text, single accent
  color, controller-family palette: paper lookahead blue-grey / our
  physical controllers deep blue / exploit red), tabular numerals
- i18n dictionaries (en/zh) with runtime switching

## Data pipeline

`scripts/precompute/` (Python + Julia) converts raw results into
`public/data/*.json` — 8 controllers (Dummy / MPC / OLFC / SDP /
SDP-AR(1) / `S_AR` / `R_P` / `R_FE96`) × 3 levels (endpoints / per-site /
process), on a unified continuous-SOC convention.

## Run

```sh
pnpm install
pnpm dev       # dev server at http://localhost:4321
pnpm build     # static output to dist/
pnpm preview   # serve the built site
```

## License

Apache-2.0 (same as the parent repository).
