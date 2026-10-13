import type { Check } from '../../src/lib/types';
import { DEDUPED_FIRST_DELIVERY } from '../../src/lib/sql';

// -- ============================================================
// -- CHECK: BR08 – access events fall in the expected local year
// -- WHAT I'M TESTING: I am checking that every check_in, check_out,
// --   and friend_visit falls in the expected calendar year when
// --   converted to the local time zone of the branch.  The year is
// --   read from the CHECK_YEAR environment variable (default: 2024).
// --   Events outside this year indicate a clock error or data load
// --   issue.
// -- WHY: Out-of-year events distort monthly and annual aggregates
// --   in every report.  A 2023 event counted in a 2024 report, or a
// --   2025 event excluded from a 2024 report, produces wrong totals.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

const expectedYear = parseInt(process.env.CHECK_YEAR ?? '2024', 10);

export const check: Check = {
  id: 'BR08',
  name: `All access events fall in local calendar year ${expectedYear}`,
  severity: 'warning',
  params: [expectedYear],
  sql: `
    WITH deduped AS (${DEDUPED_FIRST_DELIVERY})
    SELECT
      e.event_id,
      e.event_type,
      e.event_ts,
      e.event_ts AT TIME ZONE b.timezone  AS local_ts,
      b.name                              AS branch_name
    FROM deduped e
    JOIN branches b ON b.branch_id = e.branch_id
    WHERE lower(e.event_type) IN ('check_in', 'check_out', 'friend_visit')
      AND extract(year FROM e.event_ts AT TIME ZONE b.timezone) != $1
    ORDER BY e.event_ts
  `,
};
