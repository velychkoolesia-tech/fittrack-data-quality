export type Severity = 'blocking' | 'warning';

/**
 * negative   – SQL returns rows when a rule is violated (the default)
 * positive   – SQL returns rows when an expected good condition is ABSENT
 * edge-case  – SQL targets a specific boundary condition
 * exploratory– SQL always returns a stats summary row; never blocks
 */
export type CheckKind = 'negative' | 'positive' | 'edge-case' | 'exploratory';

export interface Check {
  id: string;
  name: string;
  severity: Severity;
  kind?: CheckKind;   // default: 'negative'
  sql: string;
  params?: unknown[];
}

export interface CheckResult {
  check: Check;
  passed: boolean;
  rowCount: number;
  sample: Record<string, unknown>[];
  error?: string;
}
