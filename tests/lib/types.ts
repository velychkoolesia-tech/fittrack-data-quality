export type Severity = 'blocking' | 'warning';

export interface Check {
  id: string;
  name: string;
  severity: Severity;
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
