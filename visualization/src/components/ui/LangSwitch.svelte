<script lang="ts">
  /** Language switcher — runtime toggle zh/en with full DOM text replacement.
   *  Static text lives in Astro-rendered HTML, so switching must rewrite
   *  [data-i18n] elements and the nav labels in the DOM, not just JS state. */
  import { getLang, setLang, onLang, t } from '../../lib/i18n';
  import { onMount } from 'svelte';

  let active = $state<'zh' | 'en'>(getLang());
  $effect(() => onLang((l) => (active = l)));

  function apply() {
    document.documentElement.lang = getLang();
    document.querySelectorAll<HTMLElement>('[data-i18n]').forEach((el) => {
      const key = el.dataset.i18n;
      if (key) el.textContent = t(key);
    });
    document.querySelectorAll<HTMLAnchorElement>('.site-nav a[data-i18n-key]').forEach((a) => {
      const key = a.dataset.i18nKey;
      if (key) a.textContent = t(`nav.${key}`);
    });
  }

  onMount(() => apply()); // apply persisted language on every page load

  function set(l: 'zh' | 'en') {
    setLang(l);
    apply();
  }
</script>

<div class="lang-switch">
  <button class:active={active === 'zh'} onclick={() => set('zh')}>中文</button>
  <button class:active={active === 'en'} onclick={() => set('en')}>EN</button>
</div>
