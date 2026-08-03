<script lang="ts">
  /** 07: process comparison — cumulative cost + SOC over the representative week, controllers selectable. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { data } from '../../lib/data';
  import { palette, axisStyle, seriesFor, font } from '../../lib/palette';
  import { useI18n } from '../../lib/useI18n';
  import type { ControllerId } from '../../lib/types';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

  let selected = $state<ControllerId[]>(['S_AR', 'R_P', 'MPC', 'SDP']);
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;
  let seriesCache = new Map<string, { cumCost: number[]; soc: number[]; daily: number[] }>();

  onMount(async () => {
    chart = echarts.init(container);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });

  $effect(async () => {
    if (!chart) return;
    const rows: { name: string; cum: number[]; soc: number[]; color: string }[] = [];
    for (const cid of selected) {
      let s = seriesCache.get(cid);
      if (!s) {
        const d = await data.process(cid);
        s = { cumCost: d.steps.map((x) => x.cumCost), soc: d.steps.map((x) => x.soc), daily: d.dailyCost };
        seriesCache.set(cid, s);
      }
      rows.push({ name: cid, cum: s.cumCost, soc: s.soc, color: seriesFor[cid] });
    }
    const opt: echarts.EChartsOption = {
      tooltip: { trigger: 'axis' },
      legend: { top: 0, textStyle: { fontFamily: font } },
      grid: { left: 56, right: 56, top: 32, bottom: 40 },
      xAxis: { type: 'category', data: rows[0]?.cum.map((_, i) => i + 1) ?? [], ...axisStyle },
      yAxis: [
        { type: 'value', name: 'cumulative cost', ...axisStyle },
        { type: 'value', name: 'SOC', min: 0, max: 1, ...axisStyle },
      ],
      series: [
        ...rows.map((r) => ({ name: `${r.name} cum`, type: 'line', data: r.cum, itemStyle: { color: r.color }, symbol: 'none' })),
        ...rows.map((r) => ({ name: `${r.name} SOC`, type: 'line', yAxisIndex: 1, data: r.soc, itemStyle: { color: r.color }, symbol: 'none', lineStyle: { type: 'dashed' } })),
      ],
    };
    chart.setOption(opt, { notMerge: true });
  });
</script>

<fieldset style="border:none;padding:0;margin:0 0 8px;display:flex;gap:10px;flex-wrap:wrap;">
  {#each (['S_AR', 'R_P', 'R_FE96', 'MPC', 'SDP', 'Dummy', 'SDP-AR(1)'] as const) as cid}
    <label style="display:inline-flex;gap:4px;align-items:center;">
      <input type="checkbox" checked={selected.includes(cid)} onchange={() => (selected = selected.includes(cid) ? selected.filter((x) => x !== cid) : [...selected, cid])} />
      <span style="color:{seriesFor[cid]}">{cid}</span>
    </label>
  {/each}
</fieldset>
<div bind:this={container} style="width:100%;height:460px;"></div>
