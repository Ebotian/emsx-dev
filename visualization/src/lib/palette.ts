/**
 * Design tokens — Helvetica-style, restrained.
 * No gradients, no decorative shadows; 8px grid; tabular numerals.
 */
export const font = "'Helvetica Neue', Helvetica, Arial, sans-serif";

export const palette = {
  // neutrals
  ink: '#1a1a1a',
  muted: '#6b7280',
  faint: '#9ca3af',
  grid: '#e5e7eb',
  bg: '#f5f5f5',
  card: '#ffffff',
  border: '#d1d5db',

  // single accent (our physical controllers, primary series)
  accent: '#1f4e79',

  // controller families
  // paper lookahead (MPC / OLFC / SDP): cool grey-blues
  paperLookahead: ['#8a9bb0', '#5f7391', '#45586f'],
  // our physical controllers (S_AR / R_P / R_FE96): deep blues
  ours: ['#1f4e79', '#2f6db0', '#3e8ed0'],
  // exploit / violations / negatives
  danger: '#b91c1c',
} as const;

export const seriesFor = {
  MPC: palette.paperLookahead[0],
  'OLFC-10': palette.paperLookahead[1],
  SDP: palette.paperLookahead[2],
  'SDP-AR(1)': '#64748b',
  S_AR: palette.ours[0],
  R_P: palette.ours[1],
  R_FE96: palette.ours[2],
  Dummy: palette.faint,
} as const;

export const axisStyle = {
  axisLine: { lineStyle: { color: palette.border } },
  axisTick: { show: false },
  axisLabel: { color: palette.muted, fontFamily: font },
  splitLine: { lineStyle: { color: palette.grid } },
} as const;

/** 8px grid */
export const sp = (n: number) => `${n * 8}px`;
