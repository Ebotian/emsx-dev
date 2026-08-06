<script lang="ts">
  /** Per-site final-result gains — paper gain_by_rmse / gain_by_gap analogue.
   *  Gain = dummy_cost - controller_cost (absolute saving, paper convention).
   *  Perfect-prediction upper bound = dummy - LP oracle cost (dashed, per-site).
   *  Controllers drawn as scatter symbols (sites are discrete — no connecting lines);
   *  rank by 24h forecast RMSE or site id. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette, seriesFor } from '../../lib/palette';
  import type { ControllerId } from '../../lib/types';

  type Row = { site: number; rmse96: number; dummy_cost: number; gains: Record<string, number>; lp_gain?: number };
  const DEFAULT_CTRL: ControllerId[] = ['S_AR', 'R_P', 'R_FE96', 'MPC', 'SDP', 'SDP-AR(1)'];
  const ALL_CTRL: ControllerId[] = ['Dummy', 'MPC', 'OLFC-10', 'SDP', 'SDP-AR(1)', 'S_AR', 'R_P', 'R_FE96'];

  let ready = $state(false);
  let sortBy = $state<'rmse' | 'site'>('rmse');
  let selected = $state<ControllerId[]>(DEFAULT_CTRL);
  let rows: Row[] = [];

  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});

  onMount(async () => {
    const res = await fetch('/data/site_gain.json', { cache: 'no-store' });
    rows = await res.json();
    ready = true;
  });

  function toggle(c: ControllerId) {
    selected = selected.includes(c) ? selected.filter((x) => x !== c) : [...selected, c];
  }

  $effect(() => {
    if (!ready) return;
    const byRmse = sortBy === 'rmse';
    const order = byRmse
      ? [...rows].sort((a, b) => a.rmse96 - b.rmse96)
      : [...rows].sort((a, b) => a.site - b.site);
    // rank axis: sites occupy equal slots 1..70 in RMSE order (paper Fig.3 style);
    // tick labels show the actual RMSE at that rank. Avoids long-tail crowding.
    const rmseAtRank = new Map(order.map((r, i) => [i + 1, r.rmse96]));
    const xs = order.map((r, i) => (byRmse ? i + 1 : `#${r.site}`));
    const cd = (r: Row, i: number) => [r.site, i + 1, r.rmse96, r.dummy_cost];
    const headTpl =
      '<b>site %{customdata[0]}</b> (rank %{customdata[1]}, 24h RMSE %{customdata[2]:.1f}, dummy %{customdata[3]:.0f})<br/>%{fullData.name}: %{y:.1f}<extra></extra>';
    const lineTpl = '%{fullData.name}: %{y:.1f}<extra></extra>';

    const traces: any[] = [];
    if (order[0]?.lp_gain !== undefined) {
      traces.push({
        type: 'scatter',
        mode: 'lines',
        name: 'perfect-prediction upper bound (LP)',
        x: xs,
        y: order.map((r) => r.lp_gain!),
        line: { color: palette.danger, dash: 'dash', width: 1.5 },
        customdata: order.map(cd),
        hovertemplate: headTpl,
      });
    }
    traces.push({
      type: 'scatter',
      mode: 'lines',
      name: 'dummy (zero gain)',
      x: xs,
      y: order.map(() => 0),
      line: { color: palette.faint, dash: 'dot', width: 1.2 },
      customdata: order.map(cd),
      hovertemplate: traces.length === 0 ? headTpl : lineTpl,
    });
    for (const c of selected) {
      traces.push({
        type: 'scatter',
        mode: 'markers',
        name: c,
        x: xs,
        y: order.map((r) => r.gains[c] ?? 0),
        marker: { color: seriesFor[c], size: 6 },
        customdata: order.map(cd),
        hovertemplate: lineTpl,
      });
    }
    data = traces;

    layout = {
      legend: { orientation: 'h', x: 0, y: 1.12 },
      hovermode: 'x unified',
      margin: { l: 64, r: 24, t: 56, b: 52 },
      xaxis: byRmse
        ? {
            title: 'sites ranked by 24h forecast RMSE (tick = RMSE kWh)',
            range: [1, 70],
            tickmode: 'array',
            tickvals: Array.from({ length: 14 }, (_, i) => 1 + i * 5),
            ticktext: Array.from({ length: 14 }, (_, i) => rmseAtRank.get(1 + i * 5)?.toFixed(0) ?? ''),
          }
        : { type: 'category', title: 'site id →', showticklabels: false },
      yaxis: { title: 'gain = dummy − cost' },
    };
  });
</script>

<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
  <select bind:value={sortBy} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
    <option value="rmse">按 24h 预测 RMSE 排序</option>
    <option value="site">按站点号排序</option>
  </select>
  <span style="display:flex;gap:8px;flex-wrap:wrap;">
    {#each ALL_CTRL as c}
      <label style="display:inline-flex;gap:3px;align-items:center;font-size:12px;cursor:pointer;">
        <input type="checkbox" checked={selected.includes(c)} onchange={() => toggle(c)} />
        <span style="color:{seriesFor[c]}">{c}</span>
      </label>
    {/each}
  </span>
</div>
{#if ready && data.length > 0}
  <Plot {data} {layout} height={420} ariaLabel="Per-site gain of each controller over dummy, ranked by 24h forecast RMSE or site id" />
{/if}
