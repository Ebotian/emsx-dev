<script lang="ts">
  /** Paper-analogue: per-site 24h-ahead forecast RMSE over 70 sites, ranked ascending (EMSx paper Fig. 3). */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette } from '../../lib/palette';

  type Pt = { site: number; rmse96: number; rmse1: number };

  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  onMount(async () => {
    const res = await fetch('/data/site_rmse.json', { cache: 'no-store' });
    const pts: Pt[] = await res.json();
    const sorted = [...pts].sort((a, b) => a.rmse96 - b.rmse96);
    const x = sorted.map((p) => `#${p.site}`);
    data = [
      {
        type: 'bar',
        name: '24h-ahead RMSE',
        x,
        y: sorted.map((p) => p.rmse96),
        marker: { color: palette.accent },
        hovertemplate: '<b>%{x}</b><br/>24h-ahead RMSE: %{y:.2f} kWh<extra></extra>',
      },
      {
        type: 'bar',
        name: '15min-ahead RMSE',
        x,
        y: sorted.map((p) => p.rmse1),
        marker: { color: palette.paperLookahead[0] },
        hovertemplate: '<b>%{x}</b><br/>15min-ahead RMSE: %{y:.2f} kWh<extra></extra>',
      },
    ];
    layout = {
      yaxis: { title: 'RMSE (kWh)' },
      xaxis: { showticklabels: false },
      legend: { orientation: 'h', y: 1.12, x: 0 },
      hovermode: 'closest',
      bargap: 0.04,
      margin: { l: 56, r: 16, t: 40, b: 44 },
    };
    ready = true;
  });
</script>

{#if ready}
  <Plot {data} {layout} height={360} ariaLabel="Per-site 24h forecast RMSE" />
{/if}
