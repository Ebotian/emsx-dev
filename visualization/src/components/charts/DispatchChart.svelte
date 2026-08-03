<script lang="ts">
  /** 02: dispatch — 4 weeks of load/PV/net demand + SOC + control per controller, energy-balance tooltip.
   *  Three stacked panels sharing a time axis, period boundaries marked, dataZoom for scrolling. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, seriesFor, font } from '../../lib/palette';
  import type { ControllerId } from '../../lib/types';

  const P = 75; // site 1 power (kW); dt = 0.25 h
  let cid = $state<ControllerId>('S_AR');
  let ready = $state(false);
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;
  let steps: any[] = [];

  const fmtTime = (min: number) => `${Math.floor(min / 1440)}d ${Math.floor((min % 1440) / 60)}h`;
  const periodBounds = (d: { period: number }[], maxMin: number) => {
    const cuts: { min: number; period: number }[] = [];
    for (let i = 1; i < d.length; i++) {
      if (d[i].period !== d[i - 1].period) cuts.push({ min: (d[i].t - 0.5) * 15, period: d[i].period });
    }
    return cuts.map((c) => ({
      xAxis: c.min,
      label: { formatter: `period ${c.period}`, position: 'insideEndTop', fontSize: 10 },
      lineStyle: { color: palette.faint, type: 'dashed' as const },
    }));
  };

  onMount(async () => {
    const res = await fetch('/data/dispatch.json', { cache: 'no-store' });
    const payload = await res.json();
    steps = payload.steps;
    const maxMin = steps[steps.length - 1].t * 15;
    chart = echarts.init(container);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    ready = true;
    return () => ro.disconnect();
  });

  $effect(() => {
    if (!ready || steps.length === 0) return;
    const x = steps.map((s) => s.t * 15); // minutes
    const maxMin = x[x.length - 1];
    const marks = periodBounds(steps, maxMin);
    const tt = (params: any) => {
      const p = Array.isArray(params) ? params[0] : params;
      const s = steps[p.dataIndex];
      const imp = s.z + (s[`u_${cid}`] ?? 0) * P * 0.25;
      return `<b>t=${s.t} (${fmtTime(s.t * 15)}), period ${s.period}</b><br/>` +
        `load=${s.load.toFixed(1)}  pv=${s.pv.toFixed(1)}  z=${s.z.toFixed(1)}<br/>` +
        `SOC=${s[`soc_${cid}`].toFixed(3)}  u(${cid})=${s[`u_${cid}`].toFixed(3)}<br/>` +
        `import = z + u·P·Δt = ${imp.toFixed(1)} kWh`;
    };
    const opt: echarts.EChartsOption = {
      tooltip: { trigger: 'axis', formatter: tt },
      legend: { top: 0, textStyle: { fontFamily: font } },
      dataZoom: [
        { type: 'inside', xAxisIndex: [0, 1, 2], start: 0, end: 100 },
        { type: 'slider', xAxisIndex: [0, 1, 2], bottom: 4, height: 18 },
      ],
      grid: [
        { left: 56, right: 56, top: 30, height: '30%' },
        { left: 56, right: 56, top: '45%', height: '22%' },
        { left: 56, right: 56, top: '73%', height: '22%' },
      ],
      xAxis: [
        { type: 'value', min: 0, max: maxMin, axisLabel: { formatter: (v: number) => fmtTime(v), fontFamily: font }, ...axisStyle },
        { type: 'value', min: 0, max: maxMin, axisLabel: { show: false }, ...axisStyle },
        { type: 'value', min: 0, max: maxMin, axisLabel: { show: false }, ...axisStyle },
      ],
      yAxis: [
        { type: 'value', name: 'kW', ...axisStyle },
        { type: 'value', name: 'SOC', min: 0, max: 1, ...axisStyle },
        { type: 'value', name: 'u', min: -1, max: 1, ...axisStyle },
      ],
      series: [
        { name: 'load', type: 'line', data: steps.map((s, i) => [x[i], s.load]), symbol: 'none', itemStyle: { color: palette.ink } },
        { name: 'pv', type: 'line', data: steps.map((s, i) => [x[i], s.pv]), symbol: 'none', itemStyle: { color: palette.paperLookahead[0] } },
        { name: 'z_settle', type: 'line', data: steps.map((s, i) => [x[i], s.z]), symbol: 'none', lineStyle: { type: 'dashed' }, itemStyle: { color: palette.faint } },
        { name: `SOC (${cid})`, type: 'line', xAxisIndex: 1, yAxisIndex: 1, data: steps.map((s, i) => [x[i], s[`soc_${cid}`]]), symbol: 'none', itemStyle: { color: seriesFor[cid] }, areaStyle: { opacity: 0.08, color: seriesFor[cid] } },
        { name: `u (${cid})`, type: 'line', xAxisIndex: 2, yAxisIndex: 2, data: steps.map((s, i) => [x[i], s[`u_${cid}`]]), symbol: 'none', itemStyle: { color: seriesFor[cid] }, lineStyle: { width: 1.5 } },
        { type: 'line', xAxisIndex: 0, yAxisIndex: 0, data: [], markLine: { symbol: 'none', silent: true, data: marks } },
      ],
    };
    chart?.setOption(opt, { notMerge: true });
  });
</script>

<select bind:value={cid} style="margin-bottom:8px;">
  {#each (['S_AR', 'R_P', 'R_FE96', 'EXPLOIT'] as const) as c}
    <option value={c}>{c}</option>
  {/each}
</select>
<div bind:this={container} style="width:100%;height:560px;"></div>
