<script lang="ts">
  /** Dispatch-vs-forecast curve browser — all 70 sites available; default 2×2
   *  comparison of best-scheduling (33, 59) and worst-scheduling (9, 3) sites.
   *  Each panel: actual net demand z, AR(1) rolling 1-step prediction, SE forecast k=1.
   *  Single-site viewer below selects any site. Correlation, not causation. */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, font } from '../../lib/palette';

  type Curve = { site: number; actual: number[]; ar1: number[]; se: number[] };
  const DEFAULT_SITES = [33, 59, 9, 3];

  let curves = $state<Curve[]>([]);
  let scores = $state<Record<number, number>>({});
  let allSites = $state<number[]>([]);
  let selected = $state<number>(33);
  let singleReady = $state(false);

  let defaultContainers: Record<number, HTMLDivElement> = {};
  let defaultCharts: Record<number, echarts.ECharts> = {};
  let singleContainer: HTMLDivElement;
  let singleChart: echarts.ECharts | undefined;
  let observers: ResizeObserver[] = [];

  function buildOpt(site: number): echarts.EChartsOption {
    const c = curves.find((x) => x.site === site);
    if (!c) return {};
    const steps = c.actual.map((_, i) => i + 1);
    return {
      title: {
        text: `site ${site}  ·  score ${scores[site]?.toFixed(3) ?? '—'}`,
        left: 0,
        textStyle: { fontSize: 12, fontWeight: 'bold', fontFamily: font, color: palette.ink },
      },
      tooltip: { trigger: 'axis' },
      legend: { top: 24, textStyle: { fontFamily: font, fontSize: 11 } },
      grid: { left: 52, right: 14, top: 56, bottom: 26 },
      xAxis: {
        type: 'category',
        data: steps,
        name: '15-min steps',
        axisLabel: { show: false },
        ...axisStyle,
      },
      yAxis: { type: 'value', name: 'kW', scale: true, ...axisStyle },
      series: [
        { name: 'actual z', type: 'line', data: c.actual, symbol: 'none', lineStyle: { width: 1.5, color: palette.ink } },
        { name: 'AR(1) 1-step', type: 'line', data: c.ar1, symbol: 'none', lineStyle: { width: 1.2, color: palette.ours[0] } },
        { name: 'SE forecast k=1', type: 'line', data: c.se, symbol: 'none', lineStyle: { width: 1.2, color: palette.ours[2] } },
      ],
    };
  }

  onMount(async () => {
    const [cr, ps] = await Promise.all([
      fetch('/data/forecast_curves.json', { cache: 'no-store' }).then((r) => r.json()),
      fetch('/data/per_site.json', { cache: 'no-store' }).then((r) => r.json()),
    ]);
    curves = cr.sites;
    allSites = curves.map((c) => c.site).sort((a, b) => a - b);
    for (const sid of Object.keys(ps['S_AR'])) scores[+sid] = ps['S_AR'][sid].score;

    for (const sid of DEFAULT_SITES) {
      const el = defaultContainers[sid];
      if (!el) continue;
      const ch = echarts.init(el);
      ch.setOption(buildOpt(sid));
      defaultCharts[sid] = ch;
      const ro = new ResizeObserver(() => ch.resize());
      ro.observe(el);
      observers.push(ro);
    }
    singleReady = true;
    return () => observers.forEach((ro) => ro.disconnect());
  });

  $effect(() => {
    if (!singleReady || !singleContainer) return;
    if (!singleChart) {
      singleChart = echarts.init(singleContainer);
      const ro = new ResizeObserver(() => singleChart?.resize());
      ro.observe(singleContainer);
      observers.push(ro);
    }
    singleChart.setOption(buildOpt(selected), { notMerge: true });
  });
</script>

<div style="font-size:13px;color:#6b7280;margin-bottom:8px;">
  默认对照：最优调度 33/59（score 0.981 / 0.932）与最差调度 9/3（score 0.377 / 0.449）
</div>
<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;">
  {#each DEFAULT_SITES as sid}
    <div bind:this={defaultContainers[sid]} style="width:100%;height:300px;border:1px solid #eee;border-radius:6px;padding:4px;"></div>
  {/each}
</div>
<div style="margin-top:16px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">
  <label style="font-size:13px;">
    查看任意站点：
    <select bind:value={selected} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
      {#each allSites as sid}
        <option value={sid}>site {sid}（score {scores[sid]?.toFixed(3)}）</option>
      {/each}
    </select>
  </label>
</div>
<div bind:this={singleContainer} style="width:100%;height:320px;margin-top:8px;"></div>
