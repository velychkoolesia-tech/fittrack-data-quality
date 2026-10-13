/**
 * blocking – a violation fails the run (non-zero exit code)
 * warning  – a violation is reported but does not affect the exit code
 * info     – never passes or fails; the SQL returns a stats summary that is
 *            printed as [INFO] (exploratory)
 */
export type Severity = 'blocking' | 'warning' | 'info';

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
