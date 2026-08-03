<script lang="ts">
  /** Forecast confidence (%) per site vs elapsed forecast time — 70-site curve family.
   *  Default shows all sites (faint family); a dropdown multi-select filters which
   *  site curves are drawn. Confidence := R2 (%) of net-demand forecast (training data). */
  import { onMount } from 'svelte';
  import * as echarts from 'echarts';
  import { palette, axisStyle, font } from '../../lib/palette';

  const fmtTime = (min: number) =>
    min < 60 ? `${min}min` : min % 60 === 0 ? `${min / 60}h` : `${(min / 60).toFixed(1)}h`;

  let ready = $state(false);
  let open = $state(false);
  let query = $state('');
  let hiddenMap = $state<Record<number, boolean>>({}); // true = hidden; empty = show all
  let container: HTMLDivElement;
  let chart: echarts.ECharts | undefined;
  let siteIds = $state<number[]>([]);
  let seriesBySite = $state<[number, number][][]>([]); // parallel to siteIds
  let env: { minutes: number; median: number; p5: number; p95: number }[] = [];

  onMount(async () => {
    const res = await fetch('/data/site_confidence.json', { cache: 'no-store' });
    const payload = await res.json();
    const sites: { site: number; minutes: number; r2: number }[] = payload.sites;
    env = payload.envelope;
    const m = new Map<number, [number, number][]>();
    for (const r of sites) {
      if (!m.has(r.site)) m.set(r.site, []);
      m.get(r.site)!.push([r.minutes, r.r2 * 100]);
    }
    siteIds = [...m.keys()].sort((a, b) => a - b);       // whole-assign to trigger reactivity
    seriesBySite = siteIds.map((s) => m.get(s)!);
    chart = echarts.init(container);
    const ro = new ResizeObserver(() => chart?.resize());
    ro.observe(container);
    ready = true;
    return () => ro.disconnect();
  });

  const visibleSites = $derived(siteIds.filter((s) => !hiddenMap[s]));
  const allSiteIds = $derived(siteIds);

  function toggle(site: number) {
    const next = { ...hiddenMap };
    if (next[site]) delete next[site]; // restore -> remove key so counts stay correct
    else next[site] = true;
    hiddenMap = next;
  }
  const toggleAll = () => (hiddenMap = {});
  const clearAll = () => {
    const all: Record<number, boolean> = {};
    for (const s of siteIds) all[s] = true;
    hiddenMap = all;
  };
  const matched = $derived(allSiteIds.filter((s) => String(s).includes(query)));

  $effect(() => {
    if (!ready) return;
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
      legend: { top: 0, data: ['P5', 'median', 'P95'], textStyle: { fontFamily: font } },
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
        ...visibleSites.map((sid, i) => ({
          name: `site ${sid}`,
          type: 'line',
          data: seriesBySite[siteIds.indexOf(sid)],
          symbol: 'none',
          silent: true,
          lineStyle: { width: 1.2, opacity: 0.18, color: palette.paperLookahead[0] },
          emphasis: { disabled: true },
        })),
        { name: 'P5', type: 'line', data: env.map((p) => [p.minutes, p.p5 * 100]), symbol: 'none', lineStyle: { type: 'dashed', color: palette.faint } },
        { name: 'median', type: 'line', data: env.map((p) => [p.minutes, p.median * 100]), symbol: 'none', lineStyle: { width: 2.5, color: palette.accent } },
        { name: 'P95', type: 'line', data: env.map((p) => [p.minutes, p.p95 * 100]), symbol: 'none', lineStyle: { type: 'dashed', color: palette.faint } },
      ],
    };
    chart?.setOption(opt, { notMerge: true });
  });
</script>

<div style="position:relative;margin-bottom:8px;">
  <button
    onclick={() => (open = !open)}
    style="font:inherit;font-size:13px;padding:4px 10px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;cursor:pointer;color:#1a1a1a;">
    站点：{Object.keys(hiddenMap).length === 0 ? '全部 ' + allSiteIds.length : (allSiteIds.length - Object.keys(hiddenMap).length) + '/' + allSiteIds.length}
    <span style="margin-left:6px;font-size:10px;color:#888;">▾</span>
  </button>
  {#if open}
    <div style="position:absolute;top:30px;left:0;z-index:30;width:240px;background:#fff;border:1px solid #d0d0d0;border-radius:4px;box-shadow:0 2px 8px rgba(0,0,0,0.12);padding:8px;">
      <div style="display:flex;gap:6px;margin-bottom:6px;">
        <input
          bind:value={query}
          placeholder="搜索站点号"
          style="flex:1;font:inherit;font-size:12px;padding:3px 6px;border:1px solid #d0d0d0;border-radius:3px;"
        />
        <button onclick={toggleAll} style="font:inherit;font-size:12px;padding:2px 6px;border:1px solid #d0d0d0;background:#fff;cursor:pointer;">全选</button>
        <button onclick={clearAll} style="font:inherit;font-size:12px;padding:2px 6px;border:1px solid #d0d0d0;background:#fff;cursor:pointer;">清空</button>
      </div>
      <div style="max-height:220px;overflow-y:auto;border-top:1px solid #eee;padding-top:4px;">
        {#each matched as sid}
          <label style="display:flex;align-items:center;gap:5px;font-size:12px;color:#1a1a1a;padding:1px 0;cursor:pointer;">
            <input type="checkbox" checked={!hiddenMap[sid]} onchange={() => toggle(sid)} />
            site {sid}
          </label>
        {/each}
        {#if matched.length === 0}<span style="font-size:12px;color:#999;">无匹配</span>{/if}
      </div>
    </div>
  {/if}
</div>
<div bind:this={container} style="width:100%;height:400px;"></div>
