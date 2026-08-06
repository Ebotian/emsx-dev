<script lang="ts">
  /** Paper-analogue: per-site 24h-ahead forecast RMSE over 70 sites (EMSx paper Fig. 3).
   *  Default ascending by 24h RMSE; sortable by 15min RMSE or site id.
   *  X ticks show every 10th site so the ascending order is readable. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette } from '../../lib/palette';

  type Pt = { site: number; rmse96: number; rmse1: number };

  let pts: Pt[] = [];
  let sortBy = $state<'rmse96' | 'rmse1' | 'site'>('rmse96');
  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  onMount(async () => {
    const res = await fetch('/data/site_rmse.json', { cache: 'no-store' });
    pts = await res.json();
    ready = true;
  });

  $effect(() => {
    if (!ready) return;
    const order = [...pts].sort((a, b) =>
      sortBy === 'site' ? a.site - b.site : a[sortBy] - b[sortBy],
    );
    const x = order.map((p) => `#${p.site}`);
    const tickIdx = order.map((_, i) => i).filter((i) => i % 10 === 0);
    data = [
      {
        type: 'bar',
        name: '24h-ahead RMSE',
        x,
        y: order.map((p) => p.rmse96),
        marker: { color: palette.accent },
        hovertemplate: '<b>%{x}</b><br/>24h-ahead RMSE: %{y:.2f} kWh<extra></extra>',
      },
      {
        type: 'bar',
        name: '15min-ahead RMSE',
        x,
        y: order.map((p) => p.rmse1),
        marker: { color: palette.paperLookahead[0] },
        hovertemplate: '<b>%{x}</b><br/>15min-ahead RMSE: %{y:.2f} kWh<extra></extra>',
      },
    ];
    layout = {
      yaxis: { title: 'RMSE (kWh)' },
      xaxis: {
        tickmode: 'array',
        tickvals: tickIdx,
        ticktext: tickIdx.map((i) => `#${order[i].site}`),
        tickangle: -45,
      },
      legend: { orientation: 'h', y: 1.12, x: 0 },
      hovermode: 'closest',
      bargap: 0.04,
      margin: { l: 56, r: 16, t: 40, b: 60 },
    };
  });
</script>

<div style="display:flex;gap:10px;align-items:center;margin-bottom:8px;">
  <label style="font-size:13px;">
    排序：
    <select bind:value={sortBy} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
      <option value="rmse96">按 24h RMSE 升序</option>
      <option value="rmse1">按 15min RMSE 升序</option>
      <option value="site">按站点号</option>
    </select>
  </label>
</div>
{#if ready}
  <Plot {data} {layout} height={360} ariaLabel="Per-site 24h forecast RMSE, ascending" />
{/if}
