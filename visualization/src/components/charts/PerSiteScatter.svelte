<script lang="ts">
  /** 06: per-site cost comparison — pairwise delta heatmap (row=site, col=controller pair is heavy; use scatter R_P vs S_AR + a small table). */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { data } from '../../lib/data';
  import { palette, axisStyle } from '../../lib/palette';
  import { useI18n } from '../../lib/useI18n';
  import type { ControllerId } from '../../lib/types';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(async () => {
    chart = echarts.init(container);
    const per = await data.perSite();
    const a = per['S_AR'];
    const b = per['R_P'];
    const sites = Object.keys(a).map(Number).sort((x, y) => x - y);
    const pts = sites.map((s) => [a[String(s)].cost, b[String(s)].cost]);
    const above = sites.filter((s) => b[String(s)].cost < a[String(s)].cost).length; // R_P cheaper
    const opt: echarts.EChartsOption = {
      title: { text: 'R_P vs S_AR — per-site mean cost', left: 'center', textStyle: { fontSize: 13 } },
      tooltip: { trigger: 'item', formatter: (p: any) => `site ${sites[p.dataIndex]}: S_AR=${a[String(sites[p.dataIndex])].cost.toFixed(0)}, R_P=${b[String(sites[p.dataIndex])].cost.toFixed(0)}` },
      grid: { left: 56, right: 24, top: 40, bottom: 48 },
      xAxis: { type: 'value', name: 'S_AR cost', ...axisStyle },
      yAxis: { type: 'value', name: 'R_P cost', ...axisStyle },
      series: [
        {
          type: 'scatter',
          data: pts,
          symbolSize: 6,
          itemStyle: { color: (p: any) => (b[String(sites[p.dataIndex])].cost < a[String(sites[p.dataIndex])].cost ? palette.accent : palette.faint) },
          markLine: { symbol: 'none', lineStyle: { color: palette.ink, type: 'dashed' }, data: [{ type: 'average' }, { type: 'min' }] },
        },
        { type: 'line', data: sites.map((s) => [a[String(s)].cost, a[String(s)].cost]), lineStyle: { color: palette.ink, type: 'dashed' }, symbol: 'none' },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:480px;"></div>
