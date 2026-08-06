<script lang="ts">
  /** 07: process comparison — cumulative cost + SOC over the representative week, controllers selectable. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { data } from '../../lib/data';
  import { palette, seriesFor } from '../../lib/palette';
  import { useI18n } from '../../lib/useI18n';
  import type { ControllerId } from '../../lib/types';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

  let selected = $state<ControllerId[]>(['S_AR', 'R_P', 'MPC', 'SDP']);
  let ready = $state(false);
  const seriesCache = new Map<string, { cumCost: number[]; soc: number[]; daily: number[] }>();

  let traces = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});

  onMount(() => {
    ready = true;
  });

  let runId = 0;
  $effect(() => {
    if (!ready) return;
    const ids = [...selected]; // read deps synchronously — async $effect breaks Svelte 5 tracking
    const my = ++runId;
    void loadTraces(ids, my);
  });

  async function loadTraces(ids: ControllerId[], my: number) {
    const rows: { name: string; cum: number[]; soc: number[]; color: string }[] = [];
    for (const cid of ids) {
      let s = seriesCache.get(cid);
      if (!s) {
        const d = await data.process(cid);
        s = { cumCost: d.steps.map((x) => x.cumCost), soc: d.steps.map((x) => x.soc), daily: d.dailyCost };
        seriesCache.set(cid, s);
      }
      rows.push({ name: cid, cum: s.cumCost, soc: s.soc, color: seriesFor[cid] });
    }
    if (my !== runId) return; // a newer selection started while fetching — drop stale result
    const x = rows[0]?.cum.map((_, i) => i + 1) ?? [];
    traces = [
      ...rows.map((r) => ({
        name: `${r.name} cum`,
        type: 'scatter',
        mode: 'lines',
        x,
        y: r.cum,
        line: { color: r.color },
        hovertemplate: `<b>step %{x}</b><br/>${r.name} cumulative cost: %{y:.1f}<extra></extra>`,
      })),
      ...rows.map((r) => ({
        name: `${r.name} SOC`,
        type: 'scatter',
        mode: 'lines',
        x,
        y: r.soc,
        yaxis: 'y2',
        line: { color: r.color, dash: 'dash' },
        hovertemplate: `<b>step %{x}</b><br/>${r.name} SOC: %{y:.3f}<extra></extra>`,
      })),
    ];
    layout = {
      yaxis: { title: 'cumulative cost' },
      yaxis2: { title: 'SOC', range: [0, 1], overlaying: 'y', side: 'right' },
      legend: { orientation: 'h', y: 1.08, x: 0 },
      hovermode: 'x unified',
      margin: { l: 56, r: 56, t: 80, b: 40 },
    };
  }
</script>

<fieldset style="border:none;padding:0;margin:0 0 8px;display:flex;gap:10px;flex-wrap:wrap;">
  {#each (['S_AR', 'R_P', 'R_FE96', 'MPC', 'SDP', 'Dummy', 'SDP-AR(1)'] as const) as cid}
    <label style="display:inline-flex;gap:4px;align-items:center;">
      <input type="checkbox" checked={selected.includes(cid)} onchange={() => (selected = selected.includes(cid) ? selected.filter((x) => x !== cid) : [...selected, cid])} />
      <span style="color:{seriesFor[cid]}">{cid}</span>
    </label>
  {/each}
</fieldset>
{#if ready}
  <Plot data={traces} {layout} height={460} ariaLabel="Process comparison — cumulative cost and SOC over the representative week" />
{/if}
