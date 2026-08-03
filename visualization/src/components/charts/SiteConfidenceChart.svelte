<script lang="ts">
  /** Forecast confidence (%) per site vs elapsed forecast time — 70-site curve family with median/P5/P95 envelope.
   *  Confidence := R2 (%) of the net-demand forecast against realized net demand (training data). */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, font } from '../../lib/palette';

  const fmtTime = (min: number) =>
    min < 60 ? `${min}min` : min % 60 === 0 ? `${min / 60}h` : `${(min / 60).toFixed(1)}h`;

  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(async () => {
    chart = echarts.init(container);
    const res = await fetch('/data/site_confidence.json', { cache: 'no-store' });
    const payload = await res.json();
    const sites: { site: number; minutes: number; r2: number }[] = payload.sites;
    const env: { minutes: number; median: number; p5: number; p95: number }[] = payload.envelope;
    const bySite = new Map<number, [number, number][]>();
    for (const r of sites) {
      if (!bySite.has(r.site)) bySite.set(r.site, []);
      bySite.get(r.site)!.push([r.minutes, r.r2 * 100]);
    }

    const opt: echarts.EChartsOption = {
      tooltip: {
        trigger: 'axis',
        formatter: (params: any) => {
          const arr = Array.isArray(params) ? params : [params];
          const p = env[arr[0]?.dataIndex];
          if (!p) return '';
          return `<b>${fmtTime(p.minutes)}</b><br/>` +
            `median confidence: ${(p.median * 100).toFixed(1)}%<br/>` +
            `P5–P95: ${(p.p5 * 100).toFixed(1)}% – ${(p.p95 * 100).toFixed(1)}%`;
        },
      },
      legend: { top: 0, textStyle: { fontFamily: font } },
      grid: { left: 56, right: 24, top: 32, bottom: 44 },
      xAxis: {
        type: 'value',
        min: 0,
        max: 1440,
        axisLabel: { formatter: (v: number) => fmtTime(v), fontFamily: font },
        ...axisStyle,
      },
      yAxis: { type: 'value', name: 'confidence (%)', min: 0, max: 100, ...axisStyle },
      series: [
        ...[...bySite.entries()].map(([sid, pts]) => ({
          name: `site ${sid}`,
          type: 'line',
          data: pts,
          symbol: 'none',
          silent: true,
          lineStyle: { width: 1, opacity: 0.14, color: palette.paperLookahead[0] },
          emphasis: { disabled: true },
        })),
        { name: 'P5', type: 'line', data: env.map((p) => [p.minutes, p.p5 * 100]), symbol: 'none', lineStyle: { type: 'dashed', color: palette.faint } },
        { name: 'median', type: 'line', data: env.map((p) => [p.minutes, p.median * 100]), symbol: 'none', lineStyle: { width: 2.5, color: palette.accent } },
        { name: 'P95', type: 'line', data: env.map((p) => [p.minutes, p.p95 * 100]), symbol: 'none', lineStyle: { type: 'dashed', color: palette.faint } },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:400px;"></div>
