<script lang="ts">
  /** 06: per-site cost difference R_P vs S_AR — delta bar chart around zero.
   *  Raw costs differ by only ~0.3% on average, so a cost-vs-cost scatter collapses
   *  onto the diagonal; plotting the per-site difference restores resolution. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { data } from '../../lib/data';
  import { palette, axisStyle, font } from '../../lib/palette';
  import { useI18n } from '../../lib/useI18n';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

  let ready = $state(false);
  let sortBy = $state<'delta' | 'site'>('delta');
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;
  let rows: { site: number; sAr: number; rP: number; delta: number }[] = [];

  onMount(async () => {
    const per = await data.perSite();
    const a = per['S_AR'];
    const b = per['R_P'];
    rows = Object.keys(a)
      .map(Number)
      .sort((x, y) => x - y)
      .map((s) => ({
        site: s,
        sAr: a[String(s)].cost,
        rP: b[String(s)].cost,
        delta: b[String(s)].cost - a[String(s)].cost, // + R_P worse, - R_P better
      }));
    chart = echarts.init(container);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    ready = true;
    return () => ro.disconnect();
  });

  $effect(() => {
    if (!ready) return;
    const order = sortBy === 'delta'
      ? [...rows].sort((x, y) => x.delta - y.delta)
      : [...rows].sort((x, y) => x.site - y.site);
    const nBetter = rows.filter((r) => r.delta < 0).length;
    const opt: echarts.EChartsOption = {
      tooltip: {
        trigger: 'axis',
        formatter: (params: any) => {
          const p = Array.isArray(params) ? params[0] : params;
          const r = order[p.dataIndex];
          if (!r) return '';
          const sign = r.delta < 0 ? 'R_P cheaper' : r.delta > 0 ? 'S_AR cheaper' : 'equal';
          return `<b>site ${r.site}</b><br/>S_AR cost: ${r.sAr.toFixed(1)}<br/>R_P cost: ${r.rP.toFixed(1)}<br/>Δ (R_P−S_AR): <b>${r.delta.toFixed(1)}</b> — ${sign}`;
        },
      },
      grid: { left: 56, right: 24, top: 32, bottom: 44 },
      xAxis: { type: 'category', data: order.map((r) => `#${r.site}`), axisLabel: { show: false }, ...axisStyle },
      yAxis: { type: 'value', name: 'Δ cost = R_P − S_AR', ...axisStyle },
      series: [
        {
          type: 'bar',
          data: order.map((r) => ({
            value: r.delta,
            itemStyle: { color: r.delta < 0 ? palette.accent : palette.faint },
          })),
          label: { show: false },
        },
        {
          type: 'line',
          data: order.map(() => 0),
          symbol: 'none',
          lineStyle: { color: palette.ink, type: 'dashed' },
          tooltip: { show: false },
          silent: true,
        },
      ],
    };
    chart?.setOption(opt, { notMerge: true });
  });
</script>

<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
  <select bind:value={sortBy} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
    <option value="delta">按差值排序</option>
    <option value="site">按站点号排序</option>
  </select>
  <span class="note" style="font-size:12px;color:#6b7280;">蓝 = R_P 更省（{rows.filter((r) => r.delta < 0).length}/70） · 灰 = S_AR 更省</span>
</div>
<div bind:this={container} style="width:100%;height:420px;"></div>
