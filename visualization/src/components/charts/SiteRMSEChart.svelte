<script lang="ts">
  /** Paper-analogue: per-site 24h-ahead forecast RMSE over 70 sites, ranked ascending (EMSx paper Fig. 3). */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, font } from '../../lib/palette';

  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(async () => {
    chart = echarts.init(container);
    const res = await fetch('/data/site_rmse.json', { cache: 'no-store' });
    const pts: { site: number; rmse96: number; rmse1: number }[] = await res.json();
    const sorted = [...pts].sort((a, b) => a.rmse96 - b.rmse96);
    const opt: echarts.EChartsOption = {
      tooltip: {
        trigger: 'axis',
        formatter: (params: any) => {
          const arr = Array.isArray(params) ? params : [params];
          const i = arr[0]?.dataIndex;
          const p = sorted[i];
          if (!p) return '';
          return `<b>site ${p.site}</b><br/>24h-ahead RMSE: ${p.rmse96.toFixed(2)} kWh<br/>15min-ahead RMSE: ${p.rmse1.toFixed(2)} kWh`;
        },
      },
      legend: { top: 0, textStyle: { fontFamily: font } },
      grid: { left: 56, right: 16, top: 32, bottom: 44 },
      xAxis: {
        type: 'category',
        data: sorted.map((p) => `#${p.site}`),
        axisLabel: { show: false },
        ...axisStyle,
      },
      yAxis: { type: 'value', name: 'RMSE (kWh)', ...axisStyle },
      series: [
        { name: '24h-ahead RMSE', type: 'bar', data: sorted.map((p) => p.rmse96), itemStyle: { color: palette.accent } },
        { name: '15min-ahead RMSE', type: 'bar', data: sorted.map((p) => p.rmse1), itemStyle: { color: palette.paperLookahead[0] } },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:360px;"></div>
