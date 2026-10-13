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
  let blocking = 0;
  let warnings = 0;
  let passed   = 0;
  let explored = 0;

  for (const check of checks) {
    const result = await runCheck(check);

    // ── exploratory: always show stats, never block ──────────────────────
    if (result.check.kind === 'exploratory') {
      if (result.error) {
        console.error(`[ERR ] ${result.check.id} – ${result.check.name}\n       ERROR: ${result.error}`);
      } else {
        console.log(`[INFO] ${result.check.id} – ${result.check.name}`);
        result.sample.forEach(row => console.log(`       ${JSON.stringify(row)}`));
      }
      explored++;
      continue;
    }

    // ── all other kinds ───────────────────────────────────────────────────
    if (result.error) {
      const tag = result.check.severity === 'blocking' ? 'FAIL' : 'WARN';
      console.error(`[${tag}] ${result.check.id} – ${result.check.name}\n       ERROR: ${result.error}`);
      if (result.check.severity === 'blocking') blocking++; else warnings++;
      continue;
    }

    if (result.passed) {
      console.log(`[PASS] ${result.check.id} – ${result.check.name}`);
      passed++;
    } else {
      const tag    = result.check.severity === 'blocking' ? 'FAIL' : 'WARN';
      const stream = result.check.severity === 'blocking' ? console.error : console.warn;
      stream(`[${tag}] ${result.check.id} – ${result.check.name} (${result.rowCount} violation${result.rowCount === 1 ? '' : 's'})`);
      if (result.sample.length > 0) {
        stream(`       sample: ${JSON.stringify(result.sample[0])}`);
      }
      if (result.check.severity === 'blocking') blocking++; else warnings++;
    }
  }

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
