<script lang="ts">
  /** 08: persistence attribution — delta R2 vs delta S, negative evidence. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { palette } from '../../lib/palette';

  let traces = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  let ready = $state(false);

  onMount(async () => {
    const res = await fetch('/data/sensitivity.json', { cache: 'no-store' });
    const d = await res.json();
    const dr2: number[] = d.persist.dr2;
    const ds: number[] = d.persist.ds;
    traces = [
      {
        type: 'scatter',
        mode: 'markers',
        x: dr2,
        y: ds,
        marker: { color: palette.faint, size: 6 },
        hovertemplate: '<b>δR²</b>: %{x:.4f}<br>δS: %{y:.4f}<extra></extra>',
      },
    ];
    layout = {
      title: {
        text: `corr(δR², δS) = ${d.persist.corr} — no support for the persistence hypothesis`,
        font: { size: 13 },
      },
      xaxis: { title: 'δR² (AR − persistence)' },
      yaxis: { title: 'δS (R_P − S_AR)' },
      hovermode: 'closest',
      margin: { l: 56, r: 24, t: 44, b: 44 },
    };
    ready = true;
  });
</script>

{#if ready}
  <Plot data={traces} {layout} height={380} ariaLabel="Persistence attribution: delta R2 vs delta S scatter" />
{/if}
