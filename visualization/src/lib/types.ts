/** Shared data model for the visualization site. */

export type ControllerId =
  | 'Dummy'
  | 'MPC'
  | 'OLFC-10'
  | 'SDP'
  | 'SDP-AR(1)'
  | 'S_AR'
  | 'R_P'
  | 'R_FE96';

export const CONTROLLERS: ControllerId[] = [
  'Dummy',
  'MPC',
  'OLFC-10',
  'SDP',
  'SDP-AR(1)',
  'S_AR',
  'R_P',
  'R_FE96',
];

/** Paper lookahead / cost-to-go family grouping. */
export const FAMILY: Record<ControllerId, 'paper' | 'ours' | 'dummy'> = {
  Dummy: 'dummy',
  MPC: 'paper',
  'OLFC-10': 'paper',
  SDP: 'paper',
  'SDP-AR(1)': 'paper',
  S_AR: 'ours',
  R_P: 'ours',
  R_FE96: 'ours',
};

export interface Endpoint {
  score: number;
  cost: number;
  dummy: number;
  lp: number;
  /** paper reset-SOC official score (reference only, when available) */
  paperScore?: number;
}

export type SiteMap = Record<string, { cost: number; score: number }>;

export interface ProcessStep {
  t: number;
  soc: number;
  u: number;
  import: number;
  cumCost: number;
  z: number; // settled net demand
  violation?: boolean;
}

export interface ProcessSeries {
  site: string;
  period: string;
  steps: ProcessStep[];
  dailyCost: number[];
}

export interface AccuracyPoint {
  horizon: number;
  /** elapsed forecast time in minutes (horizon * 15) */
  minutes: number;
  rmse: number;
  mae: number;
  bias: number;
  r2: number;
  /** empirical coverage of the nominal 50/80/95 intervals */
  cov50: number;
  cov80: number;
  cov95: number;
  /** residual interval widths (uncertainty growth with horizon) */
  width50: number;
  width80: number;
  width95: number;
  n: number;
}
