/**
 * Typed JSON data loading from public/data/*.json.
 * Small files may be inlined at build via Astro imports; larger ones are
 * fetched at runtime. All controllers' data is precomputed (parallel).
 */
import type { AccuracyPoint, ControllerId, Endpoint, ProcessSeries, SiteMap } from './types';

async function load<T>(path: string): Promise<T> {
  const res = await fetch(path, { cache: 'no-store' });
  if (!res.ok) throw new Error(`failed to load ${path}: ${res.status}`);
  return (await res.json()) as T;
}

const cache = new Map<string, Promise<unknown>>();
function cached<T>(path: string): Promise<T> {
  let p = cache.get(path) as Promise<T> | undefined;
  if (!p) {
    p = load<T>(path);
    cache.set(path, p);
  }
  return p;
}

export const data = {
  endpoints: () => cached<Record<ControllerId, Endpoint>>('/data/endpoints.json'),
  perSite: () => cached<Record<ControllerId, SiteMap>>('/data/per_site.json'),
  process: (c: string) => cached<ProcessSeries>(`/data/process/${c}.json`),
  accuracy: () => cached<AccuracyPoint[]>('/data/accuracy.json'),
  journey: () => cached<{ step: string; score: number; labelKey: string }[]>('/data/journey.json'),
};
