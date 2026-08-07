<script lang="ts">
  /** Controller one-step forecast comparison (test set, out-of-sample).
   *  Difference curve: diff = SE(k=1) RMSE − controller forecast RMSE per site,
   *  ranked ascending (AR(1) primary, monotonic); persistence drawn on the same
   *  order. Zero line = parity with the dataset forecast; ABOVE zero the
   *  controller forecast is more accurate (consistent with the other external
   *  comparison charts: diff = baseline − ours, above zero = ours better).
   *  asinh y-scale keeps the small per-site differences readable while
   *  containing the #62 scale-outlier. Marked sites: best 33/59, worst 9/3. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette, seriesFor } from '../../lib/palette';

  type Metrics = { rmse: number; mae: number; bias: number; r2: number };
  type SiteRow = { site: number; n: number; ar1: Metrics; se: Metrics; persist: Metrics };

  const MARKED = new Set([33, 59, 9, 3, 62]);
  const asinh = (x: number) => Math.asinh(x);

  let traces = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  onMount(async () => {
    const res = await fetch('/data/controller_forecast.json', { cache: 'no-store' });
    const payload = await res.json();
    const sites: SiteRow[] = payload.sites;

    const diff = (s: SiteRow, c: 'ar1' | 'persist') => s.se.rmse - s[c].rmse;
    const order = [...sites].sort((a, b) => diff(a, 'ar1') - diff(b, 'ar1'));

    const x = order.map((s) => `#${s.site}`);
    const labels = order.map((s) => (MARKED.has(s.site) ? `#${s.site}` : ''));
    const mkCust = (c: 'ar1' | 'persist') =>
      order.map((s) => [
        s.site,
        s.n,
        s[c].rmse.toFixed(2),
        String(s[c].r2),
        s.se.rmse.toFixed(2),
        diff(s, c).toFixed(2),
      ]);
    const tpl =
      '<b>site %{customdata[0]}</b> (n=%{customdata[1]})<br>' +
      '%{fullData.name}: RMSE %{customdata[2]} · r² %{customdata[3]}<br>' +
      'SE(k=1) RMSE: %{customdata[4]} kWh<br>diff: %{customdata[5]} kWh<extra></extra>';

    const ticks = [-500, -100, -30, -10, -3, -1, 0, 1, 3, 10, 30, 100, 500];
    traces = [
      {
        name: 'zero (= SE forecast)',
        type: 'scatter',
        mode: 'lines',
        x,
        y: order.map(() => 0),
        line: { color: palette.faint, dash: 'dot', width: 1.2 },
        hoverinfo: 'skip',
      },
      {
        name: 'AR(1) — S_AR actual',
        type: 'scatter',
        mode: 'lines+markers',
        x,
        y: order.map((s) => asinh(diff(s, 'ar1'))),
        line: { color: seriesFor['S_AR'], width: 1.4 },
        marker: { color: seriesFor['S_AR'], size: 5 },
        text: labels,
        textposition: 'middle right',
        textfont: { size: 10, color: palette.ink },
        customdata: mkCust('ar1'),
        hovertemplate: tpl,
      },
      {
        name: 'persistence',
        type: 'scatter',
        mode: 'lines+markers',
        x,
        y: order.map((s) => asinh(diff(s, 'persist'))),
        line: { color: palette.paperLookahead[2], width: 1.1 },
        marker: { color: palette.paperLookahead[2], size: 4, opacity: 0.7 },
        customdata: mkCust('persist'),
        hovertemplate: tpl,
      },
    ];
    layout = {
      legend: { orientation: 'h', y: 1.12, x: 0 },
      hovermode: 'x',
      margin: { l: 72, r: 30, t: 44, b: 56 },
      xaxis: {
        type: 'category',
        categoryorder: 'trace',
        title: 'sites ranked by SE(k=1) − AR(1) RMSE',
        showticklabels: false,
      },
      yaxis: {
        title: 'SE(k=1) RMSE − controller RMSE (kWh, asinh)',
        tickvals: ticks.map(asinh),
        ticktext: ticks.map(String),
        zeroline: false,
      },
    };
    ready = true;
  });
</script>

{#if ready}
  <Plot data={traces} {layout} height={420} ariaLabel="Controller one-step forecast RMSE difference vs the dataset forecast" />
{/if}
