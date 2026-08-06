<script lang="ts">
  /** 06: per-site cost difference R_P vs S_AR — delta bar chart around zero.
   *  Raw costs differ by only ~0.3% on average, so a cost-vs-cost scatter collapses
   *  onto the diagonal; plotting the per-site difference restores resolution. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { data } from '../../lib/data';
  import { palette } from '../../lib/palette';
  import { useI18n } from '../../lib/useI18n';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

  let ready = $state(false);
  let sortBy = $state<'delta' | 'site'>('delta');
  let rows: { site: number; sAr: number; rP: number; delta: number }[] = [];

  let traces = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});

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
    ready = true;
  });

  $effect(() => {
    if (!ready) return;
    const order = sortBy === 'delta'
      ? [...rows].sort((x, y) => x.delta - y.delta)
      : [...rows].sort((x, y) => x.site - y.site);
    traces = [
      {
        type: 'bar',
        x: order.map((r) => `#${r.site}`),
        y: order.map((r) => r.delta),
        marker: { color: order.map((r) => (r.delta < 0 ? palette.accent : palette.faint)) },
        customdata: order.map((r) => [
          r.site,
          r.sAr.toFixed(1),
          r.rP.toFixed(1),
          r.delta.toFixed(1),
          r.delta < 0 ? 'R_P cheaper' : r.delta > 0 ? 'S_AR cheaper' : 'equal',
        ]),
        hovertemplate:
          '<b>site %{customdata[0]}</b><br/>S_AR cost: %{customdata[1]}<br/>R_P cost: %{customdata[2]}<br/>Δ (R_P−S_AR): <b>%{customdata[3]}</b> — %{customdata[4]}<extra></extra>',
      },
      {
        type: 'scatter',
        mode: 'lines',
        x: order.map((r) => `#${r.site}`),
        y: order.map(() => 0),
        line: { color: palette.ink, dash: 'dash' },
        hoverinfo: 'skip',
        showlegend: false,
      },
    ];
    layout = {
      yaxis: { title: 'Δ cost = R_P − S_AR' },
      xaxis: { showticklabels: false, showgrid: false },
      hovermode: 'x',
      bargap: 0.04,
      margin: { l: 56, r: 24, t: 16, b: 30 },
    };
  });
</script>

<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
  <select bind:value={sortBy} style="font:inherit;font-size:13px;padding:3px 8px;border:1px solid #d0d0d0;border-radius:4px;background:#fff;">
    <option value="delta">按差值排序</option>
    <option value="site">按站点号排序</option>
  </select>
  <span class="note" style="font-size:12px;color:#6b7280;">蓝 = R_P 更省（{rows.filter((r) => r.delta < 0).length}/70） · 灰 = S_AR 更省</span>
</div>
{#if ready}
  <Plot data={traces} {layout} height={420} ariaLabel="Per-site cost difference R_P vs S_AR" />
{/if}
