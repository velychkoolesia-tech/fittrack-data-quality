import { pool } from './lib/db';
import type { Check, CheckResult } from './lib/types';
import { checks } from './checks';

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

  for (const check of checks) {
    const result = await runCheck(check);

    const tag = result.passed
      ? 'PASS'
      : result.check.severity === 'blocking' ? 'FAIL' : 'WARN';

    const line = `[${tag}] ${result.check.id} – ${result.check.name}`;

    if (result.error) {
      console.error(`${line}\n       ERROR: ${result.error}`);
      if (result.check.severity === 'blocking') blocking++;
      else warnings++;
      continue;
    }

    if (result.passed) {
      console.log(line);
      passed++;
    } else {
      const stream = result.check.severity === 'blocking' ? console.error : console.warn;
      stream(`${line} (${result.rowCount} violation${result.rowCount === 1 ? '' : 's'})`);
      if (result.sample.length > 0) {
        stream(`       sample: ${JSON.stringify(result.sample[0])}`);
      }
      if (result.check.severity === 'blocking') blocking++;
      else warnings++;
    }
  }

  console.log(
    `\n${checks.length} checks: ${passed} passed, ${warnings} warning${warnings === 1 ? '' : 's'}, ${blocking} blocking failure${blocking === 1 ? '' : 's'}`
  );

  await pool.end();
  process.exit(blocking > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error('Runner crashed:', err);
  process.exit(1);
});
