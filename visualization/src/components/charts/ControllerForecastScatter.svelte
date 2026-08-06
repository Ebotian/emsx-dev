<script lang="ts">
  /** Controller one-step forecast comparison (test set, out-of-sample).
   *  Scatter: x = SE forecast RMSE (k=1), y = AR(1) / persistence RMSE, log scale.
   *  Below the diagonal y=x means the controller's forecast beats the dataset forecast.
   *  Marked sites: best scheduling 33/59, worst 9/3, and the scale-outlier 62. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, font } from '../../lib/palette';

  type Metrics = { rmse: number; mae: number; bias: number; r2: number };
  type SiteRow = { site: number; n: number; ar1: Metrics; se: Metrics; persist: Metrics };

  const MARKED = new Set([33, 59, 9, 3, 62]);
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(async () => {
    chart = echarts.init(container);
    const res = await fetch('/data/controller_forecast.json', { cache: 'no-store' });
    const data = await res.json();
    const sites: SiteRow[] = data.sites;

    const xmax = Math.max(...sites.map((s) => s.se.rmse)) * 1.2;
    const ymax = Math.max(...sites.map((s) => Math.max(s.ar1.rmse, s.persist.rmse))) * 1.2;
    const lo = 0.08;

    const labeled = (s: SiteRow, y: number) =>
      MARKED.has(s.site)
        ? {
            value: [s.se.rmse, y],
            site: s.site,
            label: {
              show: true,
              formatter: `#${s.site}`,
              position: 'right',
              fontSize: 10,
              color: palette.ink,
            },
          }
        : { value: [s.se.rmse, y], site: s.site };

    const opt: echarts.EChartsOption = {
      tooltip: {
        trigger: 'item',
        formatter: (p: any) => {
          const s = sites.find((x) => x.site === p.data.site);
          if (!s) return '';
          return (
            `<b>site ${s.site}</b> (n=${s.n})<br/>` +
            `AR(1):      rmse ${s.ar1.rmse.toFixed(1)} · r² ${s.ar1.r2}<br/>` +
            `SE(k=1):    rmse ${s.se.rmse.toFixed(1)} · r² ${s.se.r2}<br/>` +
            `persistence rmse ${s.persist.rmse.toFixed(1)} · r² ${s.persist.r2}`
          );
        },
      },
      legend: { top: 0, textStyle: { fontFamily: font } },
      grid: { left: 72, right: 30, top: 36, bottom: 56 },
      xAxis: {
        type: 'log',
        name: 'SE forecast RMSE (k=1, kWh)',
        min: lo,
        max: xmax,
        axisLabel: { ...axisStyle.axisLabel, formatter: (v: number) => v.toFixed(1) },
        ...axisStyle,
      },
      yAxis: {
        type: 'log',
        name: 'controller forecast RMSE (kWh)',
        min: lo,
        max: ymax,
        axisLabel: { ...axisStyle.axisLabel, formatter: (v: number) => v.toFixed(1) },
        ...axisStyle,
      },
      series: [
        {
          name: 'y = x',
          type: 'line',
          data: [
            [lo, lo],
            [xmax, xmax],
          ],
          symbol: 'none',
          lineStyle: { type: 'dashed', color: palette.faint },
          tooltip: { show: false },
        },
        {
          name: 'AR(1) — S_AR actual',
          type: 'scatter',
          data: sites.map((s) => labeled(s, s.ar1.rmse)),
          symbolSize: 7,
          itemStyle: { color: palette.ours[0] },
        },
        {
          name: 'persistence',
          type: 'scatter',
          data: sites.map((s) => ({ value: [s.se.rmse, s.persist.rmse], site: s.site })),
          symbolSize: 5,
          itemStyle: { color: palette.paperLookahead[2], opacity: 0.7 },
        },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:420px;"></div>
