<script lang="ts">
  /** F1: forecast accuracy vs horizon (RMSE/MAE/bias left, R2 right). */
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
      grid: { left: 48, right: 48, top: 32, bottom: 40 },
      xAxis: { type: 'category', data: h, name: t('common.horizon'), ...axisStyle },
      yAxis: [
        { type: 'value', name: 'RMSE / MAE / bias', ...axisStyle },
        { type: 'value', name: 'R²', min: 0, max: 1, ...axisStyle },
      ],
      series: [
        { name: 'RMSE', type: 'line', data: pts.map((p) => p.rmse), itemStyle: { color: palette.accent } },
        { name: 'MAE', type: 'line', data: pts.map((p) => p.mae), itemStyle: { color: palette.paperLookahead[0] } },
        { name: 'bias', type: 'line', data: pts.map((p) => p.bias), itemStyle: { color: palette.faint } },
        { name: 'R²', type: 'line', yAxisIndex: 1, data: pts.map((p) => p.r2), itemStyle: { color: palette.danger } },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:400px;"></div>
