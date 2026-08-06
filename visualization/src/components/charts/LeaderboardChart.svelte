<script lang="ts">
  /** Unified continuous-SOC leaderboard with controller selection. */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { useI18n } from '../../lib/useI18n';
  import { data } from '../../lib/data';
  import { palette, seriesFor } from '../../lib/palette';
  import type { ControllerId } from '../../lib/types';
  import ControllerSelect from '../ui/ControllerSelect.svelte';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);
  let selected = $state<ControllerId[]>(['S_AR', 'R_P', 'R_FE96', 'MPC', 'OLFC-10', 'SDP']);
  let ready = $state(false);
  let endpoints: Record<ControllerId, { score: number; cost: number; paperScore?: number }> | undefined;

  let traces = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});

  onMount(async () => {
    endpoints = await data.endpoints();
    ready = true;
  });

  $effect(() => {
    if (!ready || !endpoints) return;
    const rows = selected.map((id) => ({
      id,
      score: endpoints[id].score,
      paper: endpoints[id].paperScore,
    }));
    traces = [
      {
        type: 'bar',
        name: 'score',
        x: rows.map((r) => r.id),
        y: rows.map((r) => r.score),
        marker: { color: rows.map((r) => seriesFor[r.id]) },
        text: rows.map((r) => String(Number(r.score.toFixed(3)))),
        textposition: 'outside',
        cliponaxis: false,
        textfont: { size: 11 },
        hovertemplate: '<b>%{x}</b><br>score: %{y:.3f}<extra></extra>',
      },
      ...(rows.some((r) => r.paper !== undefined)
        ? [
            {
              name: 'paper',
              type: 'scatter',
              mode: 'markers',
              x: rows.filter((r) => r.paper !== undefined).map((r) => r.id),
              y: rows.filter((r) => r.paper !== undefined).map((r) => r.paper),
              marker: { color: palette.faint, size: 6 },
              hovertemplate: '<b>%{x}</b><br>paper: %{y:.3f}<extra></extra>',
            },
          ]
        : []),
    ];
    layout = {
      yaxis: { range: [0, 1] },
      legend: { orientation: 'h', y: 1.12, x: 0 },
      hovermode: 'x unified',
      bargap: 0.3,
      margin: { l: 48, r: 16, t: 44, b: 40 },
    };
  });
</script>

<ControllerSelect bind:selected onchange={(v) => (selected = v)} />
{#if ready}
  <Plot data={traces} {layout} height={420} ariaLabel="Controller leaderboard — continuous SOC score" />
{/if}
<p class="note">{t('results.officialNote')}</p>
