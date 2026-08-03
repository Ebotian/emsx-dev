<script lang="ts">
  /** 02: dispatch — load/PV/settlement z + selected controller's control & SOC, with energy-balance tooltip. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, seriesFor, font } from '../../lib/palette';
  import type { ControllerId } from '../../lib/types';

  const P = 75; // site 1 power (kW); dt = 0.25 h
  let cid = $state<ControllerId>('S_AR');
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;
  let steps: any[] = [];

  onMount(async () => {
    const res = await fetch('/data/dispatch.json', { cache: 'no-store' });
    steps = (await res.json()).steps;
    chart = echarts.init(container);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });

  $effect(() => {
    if (!chart || steps.length === 0) return;
    const tt = (p: any) => {
      const s = steps[p.dataIndex];
      const imp = s.z + (s[cid] ?? 0) * P * 0.25;
      return `t=${s.t}<br/>load=${s.load.toFixed(1)}  pv=${s.pv.toFixed(1)}  z=${s.z.toFixed(1)}<br/>` +
        `u(${cid})=${s[cid].toFixed(3)} → import = z + u·P·Δt = ${imp.toFixed(1)} kWh`;
    };
    const opt: echarts.EChartsOption = {
      tooltip: { trigger: 'axis', formatter: tt },
      legend: { top: 0, textStyle: { fontFamily: font } },
      grid: { left: 56, right: 56, top: 32, bottom: 40 },
      xAxis: { type: 'category', data: steps.map((s) => s.t), ...axisStyle },
      yAxis: [
        { type: 'value', name: 'kW', ...axisStyle },
        { type: 'value', name: 'u', min: -1, max: 1, ...axisStyle },
      ],
      series: [
        { name: 'load', type: 'line', data: steps.map((s) => s.load), symbol: 'none', itemStyle: { color: palette.ink } },
        { name: 'pv', type: 'line', data: steps.map((s) => s.pv), symbol: 'none', itemStyle: { color: palette.paperLookahead[0] } },
        { name: 'z_settle', type: 'line', data: steps.map((s) => s.z), symbol: 'none', lineStyle: { type: 'dashed' }, itemStyle: { color: palette.faint } },
        { name: `u (${cid})`, type: 'line', yAxisIndex: 1, data: steps.map((s) => s[cid]), symbol: 'none', itemStyle: { color: seriesFor[cid] } },
      ],
    };
    chart.setOption(opt, { notMerge: true });
  });
</script>

<select bind:value={cid} style="margin-bottom:8px;">
  {#each (['S_AR', 'R_P', 'R_FE96', 'EXPLOIT'] as const) as c}
    <option value={c}>{c}</option>
  {/each}
</select>
<div bind:this={container} style="width:100%;height:420px;"></div>
