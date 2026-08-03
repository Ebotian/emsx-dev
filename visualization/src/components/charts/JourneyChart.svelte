<script lang="ts">
  /** Journey ladder: score evolution across research stages (honest narrative). */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { useI18n } from '../../lib/useI18n';
  import { data } from '../../lib/data';
  import { palette, axisStyle, font } from '../../lib/palette';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

  let ready = $state(false);
  let journey = $state<{ step: string; score: number; labelKey: string }[]>([]);
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;
  const labels = $derived(journey.map((s) => (lang, t(s.labelKey))));

  onMount(async () => {
    journey = await data.journey();
    chart = echarts.init(container);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    ready = true;
    return () => ro.disconnect();
  });

  $effect(() => {
    if (!ready || journey.length === 0) return;
    const option: echarts.EChartsOption = {
      tooltip: { trigger: 'axis' },
      grid: { left: 48, right: 16, top: 24, bottom: 40 },
      xAxis: { type: 'category', data: labels, ...axisStyle },
      yAxis: { type: 'value', min: 0, max: 1, ...axisStyle },
      series: [
        {
          type: 'bar',
          data: journey.map((s) => s.score),
          itemStyle: { color: palette.accent },
          label: { show: true, position: 'top', fontFamily: font },
        },
      ],
    };
    chart?.setOption(option, { notMerge: true });
  });
</script>

<div bind:this={container} style="width:100%;height:320px;"></div>
