<script lang="ts">
  /** External dataset: S_AR vs R_P gain difference, sorted monotonically.
   *  diff = S_AR gain − R_P gain (AUD, both relative to dummy), sites ranked
   *  ascending. Above the zero line S_AR saves more than R_P; below, R_P wins.
   *  The per-site difference is tiny (both controllers share the same
   *  price-driven schedule), so the axis shows the small real spread. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette, seriesFor } from '../../lib/palette';

  type Row = { site: string; dummy_cost: number; gains: Record<string, number> };

  let { dataUrl = '/data/ausgrid/per_site_gain.json' }: { dataUrl?: string } = $props();
  let rows: Row[] = [];
  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  const diff = (r: Row) => (r.gains['S_AR'] ?? 0) - (r.gains['R_P'] ?? 0);

  onMount(async () => {
    const res = await fetch(dataUrl, { cache: 'no-store' });
    rows = await res.json();
    ready = true;
  });

  $effect(() => {
    if (!ready) return;
    const order = [...rows].sort((a, b) => diff(a) - diff(b));
    const x = order.map((r) => `#${r.site}`);
    const y = order.map(diff);
    const colors = order.map((r) => (diff(r) > 0 ? seriesFor['S_AR'] : seriesFor['R_P']));
    data = [
      {
        type: 'scatter',
        mode: 'lines+markers',
        name: 'S_AR − R_P gain',
        x,
        y,
        line: { color: palette.faint, width: 1.2 },
        marker: { color: colors, size: 5 },
        hovertemplate:
          '<b>site %{x}</b><br>S_AR gain: %{customdata[0]:.2f} AUD<br>' +
          'R_P gain: %{customdata[1]:.2f} AUD<br>diff: %{y:.3f} AUD<extra></extra>',
        customdata: order.map((r) => [r.gains['S_AR'], r.gains['R_P']]),
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'zero (controllers equal)',
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
        title: 'sites ranked by S_AR − R_P gain',
        showticklabels: false,
      },
      yaxis: { title: 'diff = S_AR gain − R_P gain (AUD)' },
    };
  });
</script>

<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
  <span style="font-size:12px;color:#6b7280;">
    diff = S_AR gain − R_P gain（AUD，均相对 dummy）；&gt; 0（零线上方）表示 S_AR 更优；按差值升序
  </span>
</div>
{#if ready}
  <Plot {data} {layout} height={420} ariaLabel="S_AR vs R_P gain difference (AUD), sorted ascending" />
{/if}
