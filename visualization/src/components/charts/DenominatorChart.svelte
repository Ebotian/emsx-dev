<script lang="ts">
  /** 08: sensitivity — D distribution + persistence correlation (negative evidence). */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette } from '../../lib/palette';

  let traces = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  onMount(async () => {
    const res = await fetch('/data/sensitivity.json', { cache: 'no-store' });
    const d = await res.json();
    const values: number[] = d.d_dist.values;
    const bins = new Map<number, number>();
    for (const v of values) {
      const b = Math.floor(v / 50) * 50;
      bins.set(b, (bins.get(b) ?? 0) + 1);
    }
    const sorted = [...bins.entries()].sort((a, b) => a[0] - b[0]);
    const median = d.d_dist.median;
    traces = [
      {
        type: 'bar',
        x: sorted.map(([x]) => x),
        y: sorted.map(([, y]) => y),
        width: 45,
        marker: { color: palette.accent },
        hovertemplate: '<b>D = %{x:.0f}</b><br>count: %{y}<extra></extra>',
      },
    ];
    layout = {
      xaxis: { title: 'D = C^d - C^a' },
      yaxis: { title: 'count' },
      hovermode: 'closest',
      // Median reference line + label.
      shapes: [
        {
          type: 'line',
          xref: 'x',
          yref: 'paper',
          x0: median,
          x1: median,
          y0: 0,
          y1: 1,
          line: { color: palette.danger, width: 1.5, dash: 'dash' },
        },
      ],
      annotations: [
        {
          x: median,
          y: 1,
          xref: 'x',
          yref: 'paper',
          yanchor: 'top',
          showarrow: false,
          text: `median ${Math.round(median)}`,
          font: { size: 11, color: palette.danger },
        },
      ],
      margin: { l: 56, r: 16, t: 24, b: 44 },
    };
    ready = true;
  });
</script>

{#if ready}
  <Plot data={traces} {layout} height={360} ariaLabel="Sensitivity: distribution of D = C^d - C^a" />
{/if}
