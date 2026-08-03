<script lang="ts">
  /** 08: persistence attribution — delta R2 vs delta S, negative evidence. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, font } from '../../lib/palette';

  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(async () => {
    const res = await fetch('/data/sensitivity.json', { cache: 'no-store' });
    const d = await res.json();
    chart = echarts.init(container);
    const pts = d.persist.dr2.map((x: number, i: number) => [x, d.persist.ds[i]]);
    const opt: echarts.EChartsOption = {
      title: { text: `corr(δR², δS) = ${d.persist.corr} — no support for the persistence hypothesis`, left: 'center', textStyle: { fontSize: 13 } },
      tooltip: { trigger: 'item' },
      grid: { left: 56, right: 24, top: 40, bottom: 44 },
      xAxis: { type: 'value', name: 'δR² (AR − persistence)', ...axisStyle },
      yAxis: { type: 'value', name: 'δS (R_P − S_AR)', ...axisStyle },
      series: [{ type: 'scatter', data: pts, symbolSize: 6, itemStyle: { color: palette.faint } }],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:380px;"></div>
