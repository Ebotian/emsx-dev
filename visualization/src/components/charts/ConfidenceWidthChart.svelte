<script lang="ts">
  /** F2: residual interval widths (50/80/95%) vs elapsed forecast time — uncertainty grows with horizon. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { data } from '../../lib/data';
  import { palette, axisStyle, font } from '../../lib/palette';

  const fmtTime = (min: number) =>
    min < 60 ? `${min}min` : min % 60 === 0 ? `${min / 60}h` : `${(min / 60).toFixed(1)}h`;

  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(async () => {
    chart = echarts.init(container);
    const pts = await data.accuracy();
    const x = pts.map((p) => p.minutes);
    const opt: echarts.EChartsOption = {
      tooltip: {
        trigger: 'axis',
        formatter: (params: any) => {
          const arr = Array.isArray(params) ? params : [params];
          const p = pts[arr[0]?.dataIndex];
          if (!p) return '';
          const head = `<b>${fmtTime(p.minutes)}</b> (horizon ${p.horizon}, n=${p.n})`;
          const rows = arr
            .map((q: any) => `${q.marker}${q.seriesName}: ${Number(q.value).toFixed(1)} kWh`)
            .join('<br/>');
          return `${head}<br/>${rows}`;
        },
      },
      legend: { top: 0, textStyle: { fontFamily: font } },
      grid: { left: 48, right: 16, top: 32, bottom: 44 },
      xAxis: {
        type: 'value',
        name: 'forecast time',
        min: 0,
        max: 1440,
        axisLabel: { formatter: (v: number) => fmtTime(v), fontFamily: font },
        ...axisStyle,
      },
      yAxis: { type: 'value', name: 'interval width (kWh)', ...axisStyle },
      series: [
        { name: '50% interval', type: 'line', data: pts.map((p) => [p.minutes, p.width50]), symbol: 'none', itemStyle: { color: palette.paperLookahead[0] } },
        { name: '80% interval', type: 'line', data: pts.map((p) => [p.minutes, p.width80]), symbol: 'none', itemStyle: { color: palette.accent } },
        { name: '95% interval', type: 'line', data: pts.map((p) => [p.minutes, p.width95]), symbol: 'none', itemStyle: { color: palette.danger } },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:360px;"></div>
