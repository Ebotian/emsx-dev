<script lang="ts">
  /** F2: nominal vs empirical interval coverage vs horizon (honest calibration). */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { data } from '../../lib/data';
  import { palette, axisStyle, font } from '../../lib/palette';
  import { useI18n } from '../../lib/useI18n';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(async () => {
    chart = echarts.init(container);
    const pts = await data.accuracy();
    const h = pts.map((p) => p.horizon);
    const opt: echarts.EChartsOption = {
      tooltip: { trigger: 'axis' },
      legend: { top: 0, textStyle: { fontFamily: font } },
      grid: { left: 48, right: 16, top: 32, bottom: 40 },
      xAxis: { type: 'category', data: h, name: t('common.horizon'), ...axisStyle },
      yAxis: { type: 'value', min: 0, max: 1, ...axisStyle },
      series: [
        { name: 'nominal 50%', type: 'line', data: pts.map(() => 0.5), lineStyle: { type: 'dashed' }, itemStyle: { color: palette.faint } },
        { name: 'cov50', type: 'line', data: pts.map((p) => p.cov50), itemStyle: { color: palette.accent } },
        { name: 'nominal 80%', type: 'line', data: pts.map(() => 0.8), lineStyle: { type: 'dashed' }, itemStyle: { color: palette.faint } },
        { name: 'cov80', type: 'line', data: pts.map((p) => p.cov80), itemStyle: { color: palette.ours[1] } },
        { name: 'nominal 95%', type: 'line', data: pts.map(() => 0.95), lineStyle: { type: 'dashed' }, itemStyle: { color: palette.faint } },
        { name: 'cov95', type: 'line', data: pts.map((p) => p.cov95), itemStyle: { color: palette.ours[2] } },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:400px;"></div>
