/**
 * i18n helper (no Svelte runes here — plain TS, safe for SSR).
 * Components wrap the returned lang in their own $state and subscribe.
 */
import { getLang, onLang, t as tStatic, type Lang } from './i18n';

export interface I18n {
  readonly lang: Lang;
  t(key: string): string;
  subscribe(fn: (l: Lang) => void): () => void;
}

export function useI18n(): I18n {
  let lang: Lang = getLang();
  const subs = new Set<(l: Lang) => void>();
  onLang((l) => {
    lang = l;
    for (const f of subs) f(l);
  });
  return {
    get lang() {
      return lang;
    },
    t: (key: string) => tStatic(key),
    subscribe(fn: (l: Lang) => void) {
      subs.add(fn);
      return () => subs.delete(fn);
    },
  };
}
