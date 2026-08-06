<script lang="ts">
  /** External dataset: dispatch-forecast curve browser (single-site viewer).
   *  Parallel to ForecastCurveBrowser but for a validation dataset: shows
   *  actual net demand z, AR(1) one-step prediction, persistence, over the
   *  first 2 days of each site's test window. Site dropdown for all sites. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette } from '../../lib/palette';

  type Curve = { site: string; actual: number[]; ar1: number[]; persist: number[] };

  let { dataUrl = '/data/ausgrid/curves.json', label = 'Ausgrid' }: { dataUrl?: string; label?: string } = $props();
  let curves = $state<Curve[]>([]);
  let allSites = $state<string[]>([]);
  let selected = $state<string>('');
  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  function buildData(site: string) {
    const c = curves.find((x) => String(x.site) === String(site));
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
        hovertemplate: '<b>step %{x}</b><br>AR(1): %{y:.2f} kW<extra></extra>',
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'persistence',
        x: steps,
        y: c.persist,
        line: { color: palette.ours[2], width: 1.2, dash: 'dot' },
        hovertemplate: '<b>step %{x}</b><br>persistence: %{y:.2f} kW<extra></extra>',
      },
    ];
  }

  const baseLayout = {
    legend: { orientation: 'h', x: 0, y: 1.12 },
    hovermode: 'x unified',
    margin: { l: 56, r: 16, t: 40, b: 40 },
    xaxis: { title: '15-min steps', showticklabels: false },
    yaxis: { title: 'kW' },
  };

  onMount(async () => {
    const res = await fetch(dataUrl, { cache: 'no-store' });
    const payload = await res.json();
    curves = payload.sites;
    allSites = curves.map((c) => String(c.site));
    if (allSites.length > 0) selected = allSites[0];
    ready = true;
  });

  $effect(() => {
    if (!ready || selected === '') return;
    data = buildData(selected);
    layout = baseLayout;
  });
</script>

<div style="margin-bottom:8px;font-size:13px;color:#6b7280;">
  {label}：每站点显示各自测试期窗口的实际净需求、AR(1) 一步预测与 persistence
</div>
<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
  <label style="font-size:13px;">
    查看站点：
    <select bind:value={selected} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
      {#each allSites as sid}
        <option value={sid}>site {sid}</option>
      {/each}
    </select>
  </label>
</div>
{#if ready}
  <Plot {data} {layout} height={360} ariaLabel={`${label} dispatch-forecast curves`} />
{/if}
