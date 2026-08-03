<script lang="ts">
  /** F1: forecast accuracy vs elapsed forecast time (15min..24h): RMSE/MAE/bias left, R2 right. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { data } from '../../lib/data';
  import { palette, axisStyle, font } from '../../lib/palette';
  import { useI18n } from '../../lib/useI18n';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

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
            .map((q: any) => `${q.marker}${q.seriesName}: ${Number(q.value[1]).toFixed(q.seriesName === 'R²' ? 4 : 2)}`)
            .join('<br/>');
          return `${head}<br/>${rows}`;
        },
      },
      legend: { top: 0, textStyle: { fontFamily: font } },
      grid: { left: 48, right: 48, top: 32, bottom: 44 },
      xAxis: {
        type: 'value',
        name: t('common.horizonTime'),
        min: 0,
        max: 1440,
        axisLabel: { formatter: (v: number) => fmtTime(v), fontFamily: font },
        ...axisStyle,
      },
      yAxis: [
        { type: 'value', name: 'RMSE / MAE / bias', ...axisStyle },
        { type: 'value', name: 'R²', min: 0, max: 1, ...axisStyle },
      ],
      series: [
        { name: 'RMSE', type: 'line', data: pts.map((p) => [p.minutes, p.rmse]), symbol: 'none', itemStyle: { color: palette.accent } },
        { name: 'MAE', type: 'line', data: pts.map((p) => [p.minutes, p.mae]), symbol: 'none', itemStyle: { color: palette.paperLookahead[0] } },
        { name: 'bias', type: 'line', data: pts.map((p) => [p.minutes, p.bias]), symbol: 'none', itemStyle: { color: palette.faint } },
        { name: 'R²', type: 'line', yAxisIndex: 1, data: pts.map((p) => [p.minutes, p.r2]), symbol: 'none', itemStyle: { color: palette.danger } },
      ],
    };
    chart.setOption(opt);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });
</script>

<div bind:this={container} style="width:100%;height:400px;"></div>
