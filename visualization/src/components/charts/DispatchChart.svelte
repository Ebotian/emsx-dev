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
    const cuts = periodBounds(steps);
    const tt = (s: any) =>
      `<b>t=${s.t} (${fmtTime(s.t * 15)}), period ${s.period}</b><br>` +
      `load=${s.load.toFixed(1)}  pv=${s.pv.toFixed(1)}  z=${s.z.toFixed(1)}<br>` +
      `SOC=${s[`soc_${cid}`].toFixed(3)}  u(${cid})=${s[`u_${cid}`].toFixed(3)}<br>` +
      `import = z + u·P·Δt = ${(s.z + (s[`u_${cid}`] ?? 0) * P * 0.25).toFixed(1)} kWh`;
    const fullTpl = '<b>%{customdata[0]}</b><extra></extra>';

    // t restarts at 1 every period; without a break, Plotly connects the last
    // point of a period to the first of the next across the whole x range
    // (a long diagonal line). Insert null at period boundaries to break the line.
    const xs: (number | null)[] = [];
    const yl: (number | null)[] = [];
    const yp: (number | null)[] = [];
    const yz: (number | null)[] = [];
    const ysoc: (number | null)[] = [];
    const yu: (number | null)[] = [];
    const cd: (string[] | null)[] = [];
    for (let i = 0; i < steps.length; i++) {
      const s = steps[i];
      if (i > 0 && s.period !== steps[i - 1].period) {
        xs.push(null); yl.push(null); yp.push(null); yz.push(null);
        ysoc.push(null); yu.push(null); cd.push(null);
      }
      xs.push(s.t * 15);
      yl.push(s.load); yp.push(s.pv); yz.push(s.z);
      ysoc.push(s[`soc_${cid}`]); yu.push(s[`u_${cid}`]);
      cd.push([tt(s)]);
    }
    const maxMin = Math.max(...xs.filter((v): v is number => v !== null));

    data = [
      {
        type: 'scatter',
        mode: 'lines',
        name: 'load',
        x: xs,
        y: yl,
        line: { color: palette.ink },
        customdata: cd,
        hovertemplate: fullTpl,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'pv',
        x: xs,
        y: yp,
        line: { color: palette.paperLookahead[0] },
        customdata: cd,
        hovertemplate: fullTpl,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: 'z_settle',
        x: xs,
        y: yz,
        line: { color: palette.faint, dash: 'dash' },
        customdata: cd,
        hovertemplate: fullTpl,
      },
      {
        type: 'scatter',
        mode: 'lines',
        name: `SOC (${cid})`,
        x: xs,
        y: ysoc,
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
        x: xs,
        y: yu,
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
      xaxis: {
        tickmode: 'array',
        tickvals,
        ticktext: tickvals.map(fmtTime),
        rangeslider: { visible: true, thickness: 0.08 },
      },
      // one shared y axis — load/pv/z in kW, SOC (0-1) and u (-1..1) drawn on
      // the same scale, time-aligned on the single x axis
      yaxis: { title: 'kW (load/pv/z) · SOC · u', autorange: true },
      shapes: cuts.map((c) => ({
        type: 'line',
        xref: 'x',
        yref: 'paper',
        x0: c.min,
        x1: c.min,
        y0: 0,
        y1: 1,
        line: { color: palette.faint, dash: 'dash', width: 1 },
      })),
      annotations: cuts.map((c) => ({
        x: c.min,
        y: 1,
        xref: 'x',
        yref: 'paper',
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
  <Plot {data} {layout} config={{ scrollZoom: true }} height={560} ariaLabel="Dispatch over 7 days: load, PV and net demand, SOC and control per controller" />
{/if}
