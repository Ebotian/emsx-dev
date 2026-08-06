<script lang="ts">
  /** Forecast confidence (%) per site vs elapsed forecast time — 70-site curve family.
   *  Default shows all sites (faint family); a dropdown multi-select filters which
   *  site curves are drawn. Confidence := R2 (%) of net-demand forecast (training data). */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette } from '../../lib/palette';

  const fmtTime = (min: number) =>
    min < 60 ? `${min}min` : min % 60 === 0 ? `${min / 60}h` : `${(min / 60).toFixed(1)}h`;

  let ready = $state(false);
  let open = $state(false);
  let query = $state('');
  let hiddenMap = $state<Record<number, boolean>>({}); // true = hidden; empty = show all
  let siteIds = $state<number[]>([]);
  let seriesBySite = $state<[number, number][][]>([]); // parallel to siteIds
  let env: { minutes: number; median: number; p5: number; p95: number }[] = [];

  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});

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
    ready = true;
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

  const tickvals = [0, 240, 480, 720, 960, 1200, 1440];
  const ticktext = tickvals.map(fmtTime);

  $effect(() => {
    if (!ready) return;
    const timeTxt = (min: number) => fmtTime(min);
    data = [
      ...visibleSites.map((sid) => {
        const pts = seriesBySite[siteIds.indexOf(sid)];
        return {
          type: 'scatter',
          mode: 'lines',
          name: `site ${sid}`,
          x: pts.map((p) => p[0]),
          y: pts.map((p) => p[1]),
          line: { color: palette.paperLookahead[0], width: 1.2 },
          opacity: 0.18,
          hoverinfo: 'skip',
          showlegend: false,
        };
      }),
      {
        type: 'scatter',
        mode: 'lines',
        name: 'P5',
        x: env.map((p) => p.minutes),
        y: env.map((p) => p.p5 * 100),
        line: { color: palette.faint, dash: 'dash' },
        customdata: env.map((p) => [timeTxt(p.minutes)]),
        hovertemplate: '<b>%{customdata[0]}</b><br/>P5: %{y:.1f}%<extra></extra>',
        legendrank: 1,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'P95',
        x: env.map((p) => p.minutes),
        y: env.map((p) => p.p95 * 100),
        line: { color: palette.faint, dash: 'dash' },
        fill: 'tonexty', // band between P95 and the preceding P5 trace
        fillcolor: 'rgba(156,163,175,0.15)',
        customdata: env.map((p) => [timeTxt(p.minutes)]),
        hovertemplate: 'P95: %{y:.1f}%<extra></extra>',
        legendrank: 3,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'median',
        x: env.map((p) => p.minutes),
        y: env.map((p) => p.median * 100),
        line: { color: palette.accent, width: 2.5 },
        customdata: env.map((p) => [timeTxt(p.minutes)]),
        hovertemplate: 'median confidence: %{y:.1f}%<extra></extra>',
        legendrank: 2,
      },
    ];
    layout = {
      legend: { orientation: 'h', x: 0, y: 1.12 },
      hovermode: 'x unified',
      margin: { l: 56, r: 24, t: 44, b: 48 },
      xaxis: { title: 'forecast time →', range: [0, 1440], tickvals, ticktext },
      yaxis: { title: 'confidence (%)', range: [0, 100] },
    };
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
{#if ready && data.length > 0}
  <Plot {data} {layout} height={400} ariaLabel="Forecast confidence per site over the 24h forecast horizon, with median and P5-P95 envelope" />
{/if}
