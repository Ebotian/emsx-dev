<script lang="ts">
  /** Unified continuous-SOC leaderboard with controller selection. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { useI18n } from '../../lib/useI18n';
  import { data } from '../../lib/data';
  import { palette, axisStyle, seriesFor, font } from '../../lib/palette';
  import { CONTROLLERS, FAMILY, type ControllerId } from '../../lib/types';
  import ControllerSelect from '../ui/ControllerSelect.svelte';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);
  let selected = $state<ControllerId[]>(['S_AR', 'R_P', 'R_FE96', 'MPC', 'OLFC-10', 'SDP']);
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;
  let endpoints: Record<ControllerId, { score: number; cost: number; paperScore?: number }> | undefined;

  onMount(async () => {
    endpoints = await data.endpoints();
    chart = echarts.init(container);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    return () => ro.disconnect();
  });

  $effect(() => {
    if (!chart || !endpoints) return;
    const rows = selected.map((id) => ({
      id,
      score: endpoints[id].score,
      paper: endpoints[id].paperScore,
    }));
    const opt: echarts.EChartsOption = {
      tooltip: { trigger: 'axis' },
      grid: { left: 48, right: 16, top: 24, bottom: 40 },
      xAxis: { type: 'category', data: rows.map((r) => r.id), ...axisStyle },
      yAxis: { type: 'value', min: 0, max: 1, ...axisStyle },
      series: [
        {
          type: 'bar',
          data: rows.map((r) => ({
            value: r.score,
            itemStyle: { color: seriesFor[r.id] },
          })),
          label: { show: true, position: 'top', fontFamily: font },
        },
        ...(rows.some((r) => r.paper !== undefined)
          ? [{
              name: 'paper',
              type: 'scatter',
              data: rows.map((r) => (r.paper !== undefined ? [r.id, r.paper] : null)),
              symbolSize: 6,
              itemStyle: { color: palette.faint },
            }]
          : []),
      ],
    };
    chart.setOption(opt, { notMerge: true });
  });
</script>

<ControllerSelect bind:selected onchange={(v) => (selected = v)} />
<div bind:this={container} style="width:100%;height:420px;"></div>
<p class="note">{t('results.officialNote')}</p>
