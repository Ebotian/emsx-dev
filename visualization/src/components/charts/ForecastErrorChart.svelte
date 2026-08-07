<script lang="ts">
  /** External dataset: one-step forecast RMSE comparison per site.
   *  Persistence = the previous actual value (z[t-1]); AR(1) = the fitted
   *  one-step forecast. Lower is better; AR(1)/persistence ratio < 1 means
   *  the AR(1) forecast beats the naive baseline (visible as a shorter bar). */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette, seriesFor } from '../../lib/palette';

  type Row = { site: string; persist_rmse: number; ar1_rmse: number };

  let { dataUrl = '/data/ausgrid/forecast_error.json' }: { dataUrl?: string } = $props();
  let rows: Row[] = [];
  let sortBy = $state<'site' | 'ratio'>('site');
  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  const ratio = (r: Row) => r.ar1_rmse / Math.max(r.persist_rmse, 1e-12);

  onMount(async () => {
    const res = await fetch(dataUrl, { cache: 'no-store' });
    rows = await res.json();
    ready = true;
  });

  $effect(() => {
    if (!ready) return;
    const order = [...rows].sort((a, b) =>
      sortBy === 'site'
        ? String(a.site).localeCompare(String(b.site), undefined, { numeric: true })
        : ratio(a) - ratio(b),
    );
    const x = order.map((r) => `#${r.site}`);
    data = [
      {
        type: 'bar',
        name: 'Persistence RMSE',
        x,
        y: order.map((r) => r.persist_rmse),
        marker: { color: palette.faint, opacity: 0.5 },
        hovertemplate: '<b>site %{x}</b><br>persistence RMSE: %{y:.2f} kW<extra></extra>',
      },
      {
        type: 'bar',
        name: 'AR(1) RMSE',
        x,
        y: order.map((r) => r.ar1_rmse),
        customdata: order.map((r) => ratio(r)),
        marker: { color: seriesFor['S_AR'], opacity: 0.85 },
        hovertemplate:
          '<b>site %{x}</b><br>AR(1) RMSE: %{y:.2f} kW<br>AR1/persist: %{customdata:.2f}<extra></extra>',
      },
    ];
    layout = {
      barmode: 'group',
      legend: { orientation: 'h', x: 0, y: 1.12 },
      hovermode: 'x',
      margin: { l: 64, r: 24, t: 56, b: 52 },
      xaxis: {
        type: 'category',
        categoryorder: 'trace',
        title: sortBy === 'site' ? 'site id →' : 'sites ranked by AR1/persist ratio',
        showticklabels: false,
      },
      yaxis: { title: 'one-step forecast RMSE (kW)' },
    };
  });
</script>

<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
  <select bind:value={sortBy} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
    <option value="site">按站点号排序</option>
    <option value="ratio">按 AR1/persist 比排序</option>
  </select>
  <span style="font-size:12px;color:#6b7280;">
    persistence = 上一时刻值；AR(1) 柱更短表示预测优于 persistence（比 &lt; 1）
  </span>
</div>
{#if ready}
  <Plot {data} {layout} height={420} ariaLabel="One-step forecast RMSE: persistence vs AR(1) per site" />
{/if}
