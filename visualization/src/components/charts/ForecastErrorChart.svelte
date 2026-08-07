<script lang="ts">
  /** External dataset: one-step forecast RMSE difference, sorted monotonically.
   *  diff = persistence RMSE − AR(1) RMSE (kW), sites ranked ascending.
   *  Positive diff (above the zero line) means the AR(1) forecast beats the
   *  naive persistence baseline; negative sites are where persistence wins. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette, seriesFor } from '../../lib/palette';

  type Row = { site: string; persist_rmse: number; ar1_rmse: number };

  let { dataUrl = '/data/ausgrid/forecast_error.json' }: { dataUrl?: string } = $props();
  let rows: Row[] = [];
  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  onMount(async () => {
    const res = await fetch(dataUrl, { cache: 'no-store' });
    rows = await res.json();
    ready = true;
  });

  $effect(() => {
    if (!ready) return;
    const order = [...rows].sort(
      (a, b) => (a.persist_rmse - a.ar1_rmse) - (b.persist_rmse - b.ar1_rmse),
    );
    const x = order.map((r) => `#${r.site}`);
    const diff = order.map((r) => r.persist_rmse - r.ar1_rmse);
    const colors = order.map((r) =>
      r.ar1_rmse < r.persist_rmse ? seriesFor['S_AR'] : palette.faint,
    );
    data = [
      {
        type: 'scatter',
        mode: 'lines+markers',
        name: 'persistence − AR(1) RMSE',
        x,
        y: diff,
        line: { color: seriesFor['S_AR'], width: 1.4 },
        marker: { color: colors, size: 5 },
        hovertemplate:
          '<b>site %{x}</b><br>persistence RMSE: %{customdata[0]:.2f} kW<br>' +
          'AR(1) RMSE: %{customdata[1]:.2f} kW<br>diff: %{y:.2f} kW<extra></extra>',
        customdata: order.map((r) => [r.persist_rmse, r.ar1_rmse]),
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'zero (no improvement)',
        x,
        y: order.map(() => 0),
        line: { color: palette.faint, dash: 'dot', width: 1.2 },
        hoverinfo: 'skip',
        showlegend: true,
      },
    ];
    layout = {
      legend: { orientation: 'h', x: 0, y: 1.12 },
      hovermode: 'x',
      margin: { l: 64, r: 24, t: 56, b: 52 },
      xaxis: {
        type: 'category',
        categoryorder: 'trace',
        title: 'sites ranked by persistence − AR(1) RMSE',
        showticklabels: false,
      },
      yaxis: { title: 'diff = persistence RMSE − AR(1) RMSE (kW)' },
    };
  });
</script>

<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
  <span style="font-size:12px;color:#6b7280;">
    diff = persistence RMSE − AR(1) RMSE；&gt; 0（零线上方）表示 AR(1) 优于 persistence，按差值升序
  </span>
</div>
{#if ready}
  <Plot {data} {layout} height={420} ariaLabel="One-step forecast RMSE difference (persistence minus AR(1)), sorted" />
{/if}
