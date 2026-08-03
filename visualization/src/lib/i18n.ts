/**
 * Minimal i18n: language dictionaries loaded from JSON (single source of
 * truth), runtime switch between 'zh' and 'en'. Deep-merge not needed —
 * the dictionaries are one-to-one keyed.
 */
import zh from './i18n/zh.json';
import en from './i18n/en.json';

export type Lang = 'zh' | 'en';
export type Dict = typeof zh;

const dicts: Record<Lang, Dict> = { zh, en };

let lang: Lang = 'zh';
const listeners = new Set<(l: Lang) => void>();

export function setLang(l: Lang): void {
  lang = l;
  for (const fn of listeners) fn(l);
}
export function getLang(): Lang {
  return lang;
}
export function onLang(fn: (l: Lang) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** t('nav.index') -> string */
export function t(key: string): string {
  const parts = key.split('.');
  let node: unknown = dicts[lang];
  for (const p of parts) {
    if (node && typeof node === 'object' && p in (node as Record<string, unknown>)) {
      node = (node as Record<string, unknown>)[p];
    } else {
      return key;
    }
  }
  return typeof node === 'string' ? node : key;
}
