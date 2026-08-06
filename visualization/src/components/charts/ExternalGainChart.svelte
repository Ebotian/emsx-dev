<script lang="ts">
  /** External dataset: per-site final-result gains (S_AR vs R_P vs dummy).
   *  Parallel to PerSiteGainChart but for a validation dataset: gain =
   *  dummy_cost - controller_cost, sorted by site or by S_AR gain. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette, seriesFor } from '../../lib/palette';

  type Row = { site: string; dummy_cost: number; gains: Record<string, number> };

  let { dataUrl = '/data/ausgrid/per_site_gain.json' }: { dataUrl?: string } = $props();
  let rows: Row[] = [];
  let sortBy = $state<'site' | 'gain'>('site');
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
    const order = [...rows].sort((a, b) =>
      sortBy === 'site'
        ? String(a.site).localeCompare(String(b.site), undefined, { numeric: true })
        : (a.gains['S_AR'] ?? 0) - (b.gains['S_AR'] ?? 0),
    );
    const x = order.map((r) => `#${r.site}`);
    data = [
      {
        type: 'scatter',
        mode: 'markers',
        name: 'S_AR gain',
        x,
        y: order.map((r) => r.gains['S_AR'] ?? 0),
        marker: { color: seriesFor['S_AR'], size: 6 },
        hovertemplate: '<b>site %{x}</b><br>S_AR gain: %{y:.1f} AUD<extra></extra>',
      },
      {
        type: 'scatter',
        mode: 'markers',
        name: 'R_P gain',
        x,
        y: order.map((r) => r.gains['R_P'] ?? 0),
        marker: { color: seriesFor['R_P'], size: 5, opacity: 0.8 },
        hovertemplate: '<b>site %{x}</b><br>R_P gain: %{y:.1f} AUD<extra></extra>',
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'dummy (zero gain)',
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
        title: sortBy === 'site' ? 'site id →' : 'sites ranked by S_AR gain',
        showticklabels: false,
      },
      yaxis: { title: 'gain = dummy − cost (AUD)' },
    };
  });
</script>

<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
  <select bind:value={sortBy} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
    <option value="site">按站点号排序</option>
    <option value="gain">按 S_AR gain 排序</option>
  </select>
  <span style="font-size:12px;color:#6b7280;">gain = dummy 成本 − 控制器成本（节省额）</span>
</div>
{#if ready}
  <Plot {data} {layout} height={420} ariaLabel="Per-site gains of S_AR and R_P over dummy" />
{/if}
