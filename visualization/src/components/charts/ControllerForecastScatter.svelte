<script lang="ts">
  /** Controller one-step forecast comparison (test set, out-of-sample).
   *  Scatter: x = SE forecast RMSE (k=1), y = AR(1) / persistence RMSE, log scale.
   *  Below the diagonal y=x means the controller's forecast beats the dataset forecast.
   *  Marked sites: best scheduling 33/59, worst 9/3, and the scale-outlier 62. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette } from '../../lib/palette';

  type Metrics = { rmse: number; mae: number; bias: number; r2: number };
  type SiteRow = { site: number; n: number; ar1: Metrics; se: Metrics; persist: Metrics };

  const MARKED = new Set([33, 59, 9, 3, 62]);

  let traces = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  onMount(async () => {
    const res = await fetch('/data/controller_forecast.json', { cache: 'no-store' });
    const payload = await res.json();
    const sites: SiteRow[] = payload.sites;

    const xmax = Math.max(...sites.map((s) => s.se.rmse)) * 1.2;
    const ymax = Math.max(...sites.map((s) => Math.max(s.ar1.rmse, s.persist.rmse))) * 1.2;
    const lo = 0.08;

    const labels = sites.map((s) => (MARKED.has(s.site) ? `#${s.site}` : ''));
    const cust = sites.map((s) => [
      s.site,
      s.n,
      s.ar1.rmse.toFixed(1),
      String(s.ar1.r2),
      s.se.rmse.toFixed(1),
      String(s.se.r2),
      s.persist.rmse.toFixed(1),
      String(s.persist.r2),
    ]);
    const tpl =
      '<b>site %{customdata[0]}</b> (n=%{customdata[1]})<br>' +
      'AR(1):      rmse %{customdata[2]} · r² %{customdata[3]}<br>' +
      'SE(k=1):    rmse %{customdata[4]} · r² %{customdata[5]}<br>' +
      'persistence rmse %{customdata[6]} · r² %{customdata[7]}<extra></extra>';

    traces = [
      {
        name: 'y = x (equal RMSE)',
        type: 'scatter',
        mode: 'lines',
        x: [lo, xmax],
        y: [lo, xmax],
        line: { color: palette.faint, dash: 'dash' },
        hoverinfo: 'skip',
      },
      {
        name: 'AR(1) — S_AR actual',
        type: 'scatter',
        mode: 'markers',
        x: sites.map((s) => s.se.rmse),
        y: sites.map((s) => s.ar1.rmse),
        text: labels,
        textposition: 'middle right',
        textfont: { size: 10, color: palette.ink },
        marker: { color: palette.ours[0], size: 7 },
        customdata: cust,
        hovertemplate: tpl,
      },
      {
        name: 'persistence',
        type: 'scatter',
        mode: 'markers',
        x: sites.map((s) => s.se.rmse),
        y: sites.map((s) => s.persist.rmse),
        marker: { color: palette.paperLookahead[2], size: 5, opacity: 0.7 },
        customdata: cust,
        hovertemplate: tpl,
      },
    ];
    layout = {
      xaxis: {
        type: 'log',
        title: 'SE forecast RMSE (k=1, kWh)',
        range: [Math.log10(lo), Math.log10(xmax)],
        tickformat: '.1f',
      },
      yaxis: {
        type: 'log',
        title: 'controller forecast RMSE (kWh)',
        range: [Math.log10(lo), Math.log10(ymax)],
        tickformat: '.1f',
      },
      legend: { orientation: 'h', y: 1.12, x: 0 },
      hovermode: 'closest',
      margin: { l: 72, r: 30, t: 44, b: 56 },
    };
    ready = true;
  });
</script>

{#if ready}
  <Plot data={traces} {layout} height={420} ariaLabel="Controller one-step forecast comparison on log scale" />
{/if}
