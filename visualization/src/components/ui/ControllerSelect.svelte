<script lang="ts">
  /** Controller multi-select grouped by family (paper / ours / dummy). */
  import { CONTROLLERS, FAMILY, type ControllerId } from '../../lib/types';
  import { palette, seriesFor } from '../../lib/palette';

  let { selected, onchange }: { selected: ControllerId[]; onchange: (v: ControllerId[]) => void } = $props();

  const family = {
    paper: CONTROLLERS.filter((c) => FAMILY[c] === 'paper'),
    ours: CONTROLLERS.filter((c) => FAMILY[c] === 'ours'),
    dummy: CONTROLLERS.filter((c) => FAMILY[c] === 'dummy'),
  };
  const groupLabel = { paper: 'paper lookahead', ours: 'ours', dummy: 'dummy' } as const;

  function toggle(id: ControllerId) {
    onchange(selected.includes(id) ? selected.filter((x) => x !== id) : [...selected, id]);
  }
</script>

<fieldset class="ctl-group">
  {#each (['paper', 'ours', 'dummy'] as const) as g}
    <span class="gname" style="color:{g === 'paper' ? palette.paperLookahead[1] : g === 'ours' ? palette.accent : palette.faint}">{groupLabel[g]}</span>
    {#each family[g] as id}
      <label class="ctl">
        <input type="checkbox" checked={selected.includes(id)} onchange={() => toggle(id)} />
        <span style="color:{seriesFor[id]}">{id}</span>
      </label>
    {/each}
  {/each}
</fieldset>

<style>
  .ctl-group { border: none; padding: 0; margin: 0 0 12px; display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
  .gname { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
  .ctl { display: inline-flex; align-items: center; gap: 4px; font-size: 13px; }
</style>
