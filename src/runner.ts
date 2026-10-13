import { pool } from './lib/db';
import type { Check, CheckResult } from './lib/types';
import { checks } from '../tests';

async function runCheck(check: Check): Promise<CheckResult> {
  try {
    const { rows } = await pool.query(check.sql, check.params);
    return {
      check,
      passed: rows.length === 0,
      rowCount: rows.length,
      sample: rows.slice(0, 3),
    };
  } catch (err) {
    return {
      check,
      passed: false,
      rowCount: -1,
      sample: [],
      error: String(err),
    };
  }
}

async function main(): Promise<void> {
  // Run every check first, then print grouped by status so the output reads
  // problems-first: FAIL -> WARN -> INFO -> PASS. All on stdout so the order is
  // exactly as written (no stdout/stderr interleaving).
  const results: CheckResult[] = [];
  for (const check of checks) results.push(await runCheck(check));

  const fail: string[] = [];
  const warn: string[] = [];
  const info: string[] = [];
  const pass: string[] = [];
  let blocking = 0, warnings = 0, passed = 0, explored = 0;

  for (const r of results) {
    const head = `${r.check.id} – ${r.check.name}`;

    // info / exploratory: stats only, never passes or fails
    if (r.check.severity === 'info') {
      explored++;
      if (r.error) {
        info.push(`[ERR ] ${head}\n       ERROR: ${r.error}`);
      } else {
        info.push([`[INFO] ${head}`, ...r.sample.map(row => `       ${JSON.stringify(row)}`)].join('\n'));
      }
      continue;
    }

    // a check errored
    if (r.error) {
      if (r.check.severity === 'blocking') { blocking++; fail.push(`[FAIL] ${head}\n       ERROR: ${r.error}`); }
      else { warnings++; warn.push(`[WARN] ${head}\n       ERROR: ${r.error}`); }
      continue;
    }

    // clean
    if (r.passed) { passed++; pass.push(`[PASS] ${head}`); continue; }

    // violations
    const vio = `(${r.rowCount} violation${r.rowCount === 1 ? '' : 's'})`;
    const sample = r.sample.length > 0 ? `\n       sample: ${JSON.stringify(r.sample[0])}` : '';
    if (r.check.severity === 'blocking') { blocking++; fail.push(`[FAIL] ${head} ${vio}${sample}`); }
    else { warnings++; warn.push(`[WARN] ${head} ${vio}${sample}`); }
  }

  for (const line of [...fail, ...warn, ...info, ...pass]) console.log(line);

  const total = checks.length - explored;
  console.log(
    `\n${total} checks (+ ${explored} exploratory): ` +
    `${passed} passed, ${warnings} warning${warnings === 1 ? '' : 's'}, ` +
    `${blocking} blocking failure${blocking === 1 ? '' : 's'}`
  );

  await pool.end();
  process.exit(blocking > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error('Runner crashed:', err);
  process.exit(1);
});
