<script lang="ts">
  /** Dispatch-vs-forecast curve browser — all 70 sites available; default 2×2
   *  comparison of best-scheduling (33, 59) and worst-scheduling (9, 3) sites.
   *  Each panel: actual net demand z, AR(1) rolling 1-step prediction, SE forecast k=1.
   *  Single-site viewer below selects any site. Correlation, not causation. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette } from '../../lib/palette';

  type Curve = { site: number; actual: number[]; ar1: number[]; se: number[] };
  const DEFAULT_SITES = [33, 59, 9, 3];

  let curves = $state<Curve[]>([]);
  let scores = $state<Record<number, number>>({});
  let allSites = $state<number[]>([]);
  let selected = $state<number>(33);
  let ready = $state(false);
  let singleReady = $state(false);

  let panelData = $state<Record<number, any[]>>({});
  let panelLayout = $state<Record<number, any>>({});

  function buildData(site: number) {
    const c = curves.find((x) => x.site === site);
    if (!c) return [];
    const steps = c.actual.map((_, i) => i + 1);
    return [
      {
        type: 'scatter',
        mode: 'lines',
        name: 'actual z',
        x: steps,
        y: c.actual,
        line: { color: palette.ink, width: 1.5 },
        hovertemplate: '<b>step %{x}</b><br>actual z: %{y:.2f} kW<extra></extra>',
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'AR(1) 1-step',
        x: steps,
        y: c.ar1,
        line: { color: palette.ours[0], width: 1.2 },
        hovertemplate: 'AR(1) 1-step: %{y:.2f} kW<extra></extra>',
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'SE forecast k=1',
        x: steps,
        y: c.se,
        line: { color: palette.ours[2], width: 1.2 },
        hovertemplate: 'SE forecast k=1: %{y:.2f} kW<extra></extra>',
      },
    ];
  }

  function buildLayout() {
    return {
      legend: { orientation: 'h', x: 0, y: 1.12 },
      hovermode: 'x unified',
      margin: { l: 56, r: 16, t: 40, b: 40 },
      xaxis: { title: '15-min steps', showticklabels: false },
      yaxis: { title: 'kW' },
    };
  }

  onMount(async () => {
    const [cr, ps] = await Promise.all([
      fetch('/data/forecast_curves.json', { cache: 'no-store' }).then((r) => r.json()),
      fetch('/data/per_site.json', { cache: 'no-store' }).then((r) => r.json()),
    ]);
    curves = cr.sites;
    allSites = curves.map((c) => c.site).sort((a, b) => a - b);
    for (const sid of Object.keys(ps['S_AR'])) scores[+sid] = ps['S_AR'][sid].score;
    for (const sid of DEFAULT_SITES) {
      panelData[sid] = buildData(sid);
      panelLayout[sid] = buildLayout();
    }
    ready = true;
    singleReady = true;
  });

  let singleData = $state<any[]>([]);
  let singleLayout = $state<Record<string, any>>({});
  $effect(() => {
    singleData = buildData(selected);
    singleLayout = buildLayout();
  });</script>

<div style="font-size:13px;color:#6b7280;margin-bottom:8px;">
  默认对照：最优调度 33/59（score 0.981 / 0.932）与最差调度 9/3（score 0.377 / 0.449）
</div>
{#if ready}
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;">
    {#each DEFAULT_SITES as sid}
      <div style="border:1px solid #eee;border-radius:6px;padding:6px;">
        <div style="font-size:12px;font-weight:bold;color:#1a1a1a;margin-bottom:2px;">
          site {sid} · score {scores[sid]?.toFixed(3) ?? '—'}
        </div>
        <Plot data={panelData[sid]} layout={panelLayout[sid]} height={300} ariaLabel={`Site ${sid}: actual net demand vs AR(1) and SE forecasts`} />
      </div>
    {/each}
  </div>
{/if}
<div style="margin-top:16px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">
  <label style="font-size:13px;">
    查看任意站点：
    <select bind:value={selected} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
      {#each allSites as sid}
        <option value={sid}>site {sid}（score {scores[sid]?.toFixed(3)}）</option>
      {/each}
    </select>
  </label>
</div>
{#if singleReady}
  <div style="border:1px solid #eee;border-radius:6px;padding:6px;margin-top:8px;">
    <div style="font-size:12px;font-weight:bold;color:#1a1a1a;margin-bottom:2px;">
      site {selected} · score {scores[selected]?.toFixed(3) ?? '—'}
    </div>
    <Plot data={singleData} layout={singleLayout} height={320} ariaLabel={`Site ${selected}: actual net demand vs AR(1) and SE forecasts`} />
  </div>
{/if}
