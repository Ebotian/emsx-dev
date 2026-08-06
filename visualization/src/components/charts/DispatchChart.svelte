<script lang="ts">
  /** 02: dispatch — 7 days of load/PV/net demand + SOC + control per controller, energy-balance tooltip.
   *  Three stacked panels sharing a time axis, period boundaries marked, rangeslider for scrolling. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette, seriesFor } from '../../lib/palette';
  import type { ControllerId } from '../../lib/types';

  const P = 75; // site 1 power (kW); dt = 0.25 h
  let cid = $state<ControllerId>('S_AR');
  let ready = $state(false);
  let steps: any[] = [];

  let data = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});

  const fmtTime = (min: number) => `${Math.floor(min / 1440)}d ${Math.floor((min % 1440) / 60)}h`;
  const periodBounds = (d: { t: number; period: number }[]) => {
    const cuts: { min: number; period: number }[] = [];
    for (let i = 1; i < d.length; i++) {
      if (d[i].period !== d[i - 1].period) cuts.push({ min: (d[i].t - 0.5) * 15, period: d[i].period });
    }
    return cuts;
  };
  const withAlpha = (hex: string | undefined, a: number) => {
    if (!hex) return undefined;
    const h = hex.replace('#', '');
    const r = parseInt(h.slice(0, 2), 16);
    const g = parseInt(h.slice(2, 4), 16);
    const b = parseInt(h.slice(4, 6), 16);
    return `rgba(${r},${g},${b},${a})`;
  };

  onMount(async () => {
    const res = await fetch('/data/dispatch.json', { cache: 'no-store' });
    const payload = await res.json();
    steps = payload.steps;
    ready = true;
  });

  $effect(() => {
    if (!ready || steps.length === 0) return;
    const x = steps.map((s) => s.t * 15); // minutes
    const maxMin = x[x.length - 1];
    const cuts = periodBounds(steps);
    // energy-balance tooltip: same text as the original formatter, carried
    // in customdata so every panel (and every trace) shows the full balance box.
    const tt = (s: any) =>
      `<b>t=${s.t} (${fmtTime(s.t * 15)}), period ${s.period}</b><br>` +
      `load=${s.load.toFixed(1)}  pv=${s.pv.toFixed(1)}  z=${s.z.toFixed(1)}<br>` +
      `SOC=${s[`soc_${cid}`].toFixed(3)}  u(${cid})=${s[`u_${cid}`].toFixed(3)}<br>` +
      `import = z + u·P·Δt = ${(s.z + (s[`u_${cid}`] ?? 0) * P * 0.25).toFixed(1)} kWh`;
    const fullTpl = '<b>%{customdata[0]}</b><extra></extra>';
    const cd = steps.map((s) => [tt(s)]);

    data = [
      {
        type: 'scatter',
        mode: 'lines',
        name: 'load',
        x,
        y: steps.map((s) => s.load),
        line: { color: palette.ink },
        customdata: cd,
        hovertemplate: fullTpl,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'pv',
        x,
        y: steps.map((s) => s.pv),
        line: { color: palette.paperLookahead[0] },
        customdata: cd,
        hovertemplate: fullTpl,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'z_settle',
        x,
        y: steps.map((s) => s.z),
        line: { color: palette.faint, dash: 'dash' },
        customdata: cd,
        hovertemplate: fullTpl,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: `SOC (${cid})`,
        xaxis: 'x2',
        yaxis: 'y2',
        x,
        y: steps.map((s) => s[`soc_${cid}`]),
        line: { color: seriesFor[cid] },
        fill: 'tozeroy',
        fillcolor: withAlpha(seriesFor[cid], 0.08),
        customdata: cd,
        hovertemplate: fullTpl,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: `u (${cid})`,
        xaxis: 'x3',
        yaxis: 'y3',
        x,
        y: steps.map((s) => s[`u_${cid}`]),
        line: { color: seriesFor[cid], width: 1.5 },
        customdata: cd,
        hovertemplate: fullTpl,
      },
    ];

    const tickvals: number[] = [];
    for (let v = 0; v <= maxMin; v += 1440) tickvals.push(v);
    layout = {
      legend: { orientation: 'h', x: 0, y: 1.12 },
      // every trace carries the full energy-balance string, so 'closest' shows it
      // verbatim on any panel (an 'x unified' box would repeat it once per trace)
      hovermode: 'closest',
      margin: { l: 56, r: 16, t: 44, b: 44 },
      xaxis: { domain: [0.06, 0.97], showticklabels: false, matches: 'x3' },
      xaxis2: { domain: [0.06, 0.97], showticklabels: false, matches: 'x3' },
      xaxis3: {
        domain: [0.06, 0.97],
        tickmode: 'array',
        tickvals,
        ticktext: tickvals.map(fmtTime),
        rangeslider: { visible: true, thickness: 0.08 },
      },
      yaxis: { domain: [0.72, 1], title: 'kW', range: [-100, 150] },
      yaxis2: { domain: [0.46, 0.65], title: 'SOC', range: [0, 1] },
      yaxis3: { domain: [0.20, 0.39], title: 'u', range: [-1, 1] },
      shapes: cuts.map((c) => ({
        type: 'line',
        xref: 'x',
        yref: 'y',
        x0: c.min,
        x1: c.min,
        y0: -100,
        y1: 150,
        line: { color: palette.faint, dash: 'dash', width: 1 },
      })),
      annotations: cuts.map((c) => ({
        x: c.min,
        y: 150,
        xref: 'x',
        yref: 'y',
        text: `period ${c.period}`,
        showarrow: false,
        xanchor: 'left',
        yanchor: 'top',
        xshift: 3,
        yshift: -2,
        font: { size: 10, color: palette.muted },
      })),
    };
  });
</script>

<select bind:value={cid} style="margin-bottom:8px;">
  {#each (['S_AR', 'R_P', 'R_FE96', 'EXPLOIT'] as const) as c}
    <option value={c}>{c}</option>
  {/each}
</select>
{#if ready && data.length > 0}
  <Plot {data} {layout} height={560} ariaLabel="Dispatch over 7 days: load, PV and net demand, SOC and control per controller" />
{/if}
