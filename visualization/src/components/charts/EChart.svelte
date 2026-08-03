<script lang="ts">
  /**
   * ECharts wrapper — owns the chart instance lifecycle:
   * init on mount, setOption on prop change (notMerge=false, lazyUpdate),
   * resize on container change, dispose on destroy.
   */
  import * as echarts from 'echarts';
  import { onMount, onDestroy } from 'svelte';
  import { font } from '../../lib/palette';

  let { option, height = 360, ariaLabel = '' }: {
    option: echarts.EChartsOption;
    height?: number;
    ariaLabel?: string;
  } = $props();

  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;

  onMount(() => {
    chart = echarts.init(container, undefined, { renderer: 'canvas' });
    chart.setOption(option);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });

  $effect(() => {
    if (chart) chart.setOption(option, { notMerge: true });
  });

  onDestroy(() => {
    chart?.dispose();
    chart = undefined;
  });
</script>

<div
  bind:this={container}
  role="img"
  aria-label={ariaLabel}
  style="width:100%;height:{height}px;font-family:{font};"
></div>
