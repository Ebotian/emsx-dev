<script lang="ts">
  /**
   * Plotly wrapper — owns the chart instance lifecycle:
   * newPlot on mount, react on prop change, purge on destroy, resize observer.
   * plotly.js is loaded dynamically (client-only) so Astro SSR never touches it.
   * Data/layout are deep-copied before being handed to Plotly: plotly mutates
   * trace objects in place (uid, _fullData, ...), which would otherwise trip
   * Svelte 5 deep reactivity on $state props and cause an effect loop.
   */
  import { onMount } from 'svelte';
  import { font } from '../../lib/palette';

  let {
    data,
    layout = {},
    config = {},
    height = 360,
    ariaLabel = '',
  }: {
    data: any[];
    layout?: Record<string, any>;
    config?: Record<string, any>;
    height?: number;
    ariaLabel?: string;
  } = $props();

  let container: HTMLDivElement;
  let Plotly: any = null;
  let initialized = false;

  const fullConfig = () => ({ responsive: true, displaylogo: false, ...config });
  // Deep copy: data/layout are plain JSON (numbers, strings, arrays) — safe to round-trip.
  const copy = (o: unknown) => JSON.parse(JSON.stringify(o));

  onMount(async () => {
    Plotly = (await import('plotly.js-basic-dist-min')).default;
    Plotly.newPlot(container, copy(data), copy(layout), fullConfig());
    initialized = true;
    const ro = new ResizeObserver(() => Plotly.Plots.resize(container));
    ro.observe(container);
    return () => {
      ro.disconnect();
      Plotly.purge(container);
    };
  });

  $effect(() => {
    if (!initialized || !Plotly) return;
    Plotly.react(container, copy(data), copy(layout), fullConfig());
  });
</script>

<div
  bind:this={container}
  role="img"
  aria-label={ariaLabel}
  style="width:100%;height:{height}px;"
></div>
