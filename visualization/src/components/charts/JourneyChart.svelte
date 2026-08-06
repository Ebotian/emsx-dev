<script lang="ts">
  /** Journey ladder: score evolution across research stages (honest narrative). */
  import { onMount } from 'svelte';
  import Plot from './Plot.svelte';
  import { useI18n } from '../../lib/useI18n';
  import { data } from '../../lib/data';
  import { palette } from '../../lib/palette';

  const i18n = useI18n();
  let lang = $state(i18n.lang);
  $effect(() => i18n.subscribe((l) => (lang = l)));
  const t = (k: string) => i18n.t(k);

  let ready = $state(false);
  let journey = $state<{ step: string; score: number; labelKey: string }[]>([]);
  let traces = $state<any[]>([]);
  let layout = $state<Record<string, any>>({});
  const labels = $derived(journey.map((s) => (lang, t(s.labelKey))));

  onMount(async () => {
    journey = await data.journey();
    ready = true;
  });

  $effect(() => {
    if (!ready || journey.length === 0) return;
    traces = [
      {
        type: 'bar',
        x: labels,
        y: journey.map((s) => s.score),
        marker: { color: palette.accent },
        text: journey.map((s) => s.score.toFixed(2)),
        textposition: 'outside',
        textfont: { size: 11 },
        hovertemplate: '<b>%{x}</b><br/>score: %{y:.2f}<extra></extra>',
      },
    ];
    layout = {
      xaxis: { showticklabels: true },
      yaxis: { title: 'score', range: [0, 1] },
      hovermode: 'closest',
      bargap: 0.3,
      margin: { l: 48, r: 16, t: 24, b: 44 },
    };
  });
</script>

{#if ready}
  <Plot data={traces} {layout} height={320} ariaLabel="Research journey score ladder" />
{/if}
