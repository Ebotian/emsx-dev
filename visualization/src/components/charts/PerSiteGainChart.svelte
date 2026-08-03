<script lang="ts">
  /** Per-site final-result gains — paper gain_by_rmse / gain_by_gap analogue.
   *  Gain = dummy_cost - controller_cost (absolute saving, paper convention).
   *  Perfect-prediction upper bound = dummy - LP oracle cost (dashed, per-site).
   *  Controllers drawn as scatter symbols (sites are discrete — no connecting lines);
   *  rank by 24h forecast RMSE or site id. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, seriesFor, font } from '../../lib/palette';
  import type { ControllerId } from '../../lib/types';

  type Row = { site: number; rmse96: number; dummy_cost: number; gains: Record<string, number>; lp_gain?: number };
  const DEFAULT_CTRL: ControllerId[] = ['S_AR', 'R_P', 'R_FE96', 'MPC', 'SDP', 'SDP-AR(1)'];
  const ALL_CTRL: ControllerId[] = ['Dummy', 'MPC', 'OLFC-10', 'SDP', 'SDP-AR(1)', 'S_AR', 'R_P', 'R_FE96'];

  let ready = $state(false);
  let sortBy = $state<'rmse' | 'site'>('rmse');
  let selected = $state<ControllerId[]>(DEFAULT_CTRL);
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;
  let rows: Row[] = [];

  onMount(async () => {
    const res = await fetch('/data/site_gain.json', { cache: 'no-store' });
    rows = await res.json();
    chart = echarts.init(container);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    ready = true;
    return () => ro.disconnect();
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
    const xs = order.map((r) => `#${r.site}`);
    const tt = (params: any) => {
      const p = Array.isArray(params) ? params[0] : params;
      const r = byRmse ? order[p.dataIndex] : order[p.dataIndex];
      if (!r) return '';
      const head = `<b>site ${r.site}</b> (24h RMSE ${r.rmse96.toFixed(1)}, dummy ${r.dummy_cost.toFixed(0)})<br/>`;
      const rows_ = (Array.isArray(params) ? params : [params])
        .map((q: any) => `${q.marker}${q.seriesName}: ${Number(q.value[1]).toFixed(1)}`)
        .join('<br/>');
      return head + rows_;
    };
    const xy = (r: Row, v: number) => (byRmse ? [r.rmse96, v] : [r.site, v]);
    const opt: echarts.EChartsOption = {
      tooltip: { trigger: 'axis', formatter: tt },
      legend: { top: 0, type: 'scroll', textStyle: { fontFamily: font } },
      grid: { left: 56, right: 24, top: 36, bottom: 48 },
      xAxis: byRmse
        ? { type: 'value', name: '24h forecast RMSE (kWh)', min: 0, ...axisStyle }
        : {
            type: 'category',
            data: xs,
            axisLabel: { show: false },
            name: 'site id →',
            ...axisStyle,
          },
      yAxis: { type: 'value', name: 'gain = dummy − cost', ...axisStyle },
      series: [
        ...(rows[0]?.lp_gain !== undefined ? [{
          name: 'perfect-prediction upper bound (LP)',
          type: 'line',
          data: order.map((r) => xy(r, r.lp_gain!)),
          symbol: 'none',
          lineStyle: { type: 'dashed', width: 1.5, color: palette.danger },
        }] : []),
        { name: 'dummy (zero gain)', type: 'line', data: order.map((r) => xy(r, 0)), symbol: 'none', lineStyle: { type: 'dotted', color: palette.faint } },
        ...selected.map((c) => ({
          name: c,
          type: 'scatter',
          data: order.map((r) => xy(r, r.gains[c] ?? 0)),
          symbolSize: 5,
          itemStyle: { color: seriesFor[c] },
          emphasis: { focus: 'series' },
        })),
      ],
    };
    chart?.setOption(opt, { notMerge: true });
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
<div bind:this={container} style="width:100%;height:420px;"></div>
