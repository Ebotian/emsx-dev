<script lang="ts">
  /** 08: sensitivity — D distribution + persistence correlation (negative evidence). */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, font } from '../../lib/palette';

  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(async () => {
    const res = await fetch('/data/sensitivity.json', { cache: 'no-store' });
    const d = await res.json();
    chart = echarts.init(container);
    const values = d.d_dist.values;
    const opt: echarts.EChartsOption = {
      tooltip: { trigger: 'axis' },
      grid: { left: 48, right: 16, top: 24, bottom: 40 },
      xAxis: { type: 'value', name: 'D = C^d - C^a', ...axisStyle },
      yAxis: { type: 'value', name: 'count', ...axisStyle },
      series: [
        {
          type: 'bar',
          data: (() => {
            const bins = new Map<number, number>();
            for (const v of values) {
              const b = Math.floor(v / 50) * 50;
              bins.set(b, (bins.get(b) ?? 0) + 1);
            }
            return [...bins.entries()].sort((a, b) => a[0] - b[0]).map(([x, y]) => [x, y]);
          })(),
          itemStyle: { color: palette.accent },
          markLine: {
            symbol: 'none',
            label: { formatter: 'median {c}', fontFamily: font },
            lineStyle: { color: palette.danger, type: 'dashed' },
            data: [{ xAxis: d.d_dist.median }],
          },
        },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:360px;"></div>
