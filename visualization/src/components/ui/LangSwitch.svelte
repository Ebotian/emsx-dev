<script lang="ts">
  /** Language switcher — runtime toggle between zh/en. */
  import { getLang, setLang, onLang } from '../../lib/i18n';

  let active = $state<'zh' | 'en'>(getLang());
  $effect(() => onLang((l) => (active = l)));
</script>

<div class="lang-switch">
  <button class:active={active === 'zh'} onclick={() => setLang('zh')}>中文</button>
  <button class:active={active === 'en'} onclick={() => setLang('en')}>EN</button>
</div>
