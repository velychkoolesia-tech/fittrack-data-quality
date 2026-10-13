import type { Check } from '../../src/lib/types';
import { DEDUPED_FIRST_DELIVERY, REGISTERED_MEMBER } from '../../src/lib/sql';

// -- ============================================================
// -- CHECK: EXP03 – branch monthly check-in count vs branch average
// -- WHAT I'M TESTING: I am computing each branch's monthly check-in
// --   count alongside its own overall monthly average.  Months
// --   where a branch is below 50 % of its average are surfaced.
// --   This identifies pipeline failures (branch went silent) or
// --   periods of unusually low activity worth investigating.
// -- WHY: A branch whose check-in pipeline breaks silently produces
// --   a near-zero count in the visit report.  Management would read
// --   this as low attendance rather than a data gap.  EXP03 makes
// --   such drops visible without requiring a manual comparison.
// -- EXPECTED: N/A – exploratory, always displays the 20 lowest
// --   month/branch combinations relative to each branch's average.
// -- SEVERITY IF IT FAILS: N/A
// -- ============================================================

export const check: Check = {
  id: 'EXP03',
  name: 'Branch monthly check-in counts vs branch average (bottom 20)',
  severity: 'info',
  sql: `
    WITH deduped AS (${DEDUPED_FIRST_DELIVERY}),
    monthly AS (
      SELECT
        e.branch_id,
        to_char(e.event_ts AT TIME ZONE b.timezone, 'YYYY-MM') AS local_month,
        count(*)                                                AS checkins
      FROM   deduped e
      JOIN   branches b ON b.branch_id = e.branch_id
      WHERE  lower(e.event_type) = 'check_in'
        AND  ${REGISTERED_MEMBER}
      GROUP  BY e.branch_id, local_month
    ),
    with_avg AS (
      SELECT
        branch_id,
        local_month,
        checkins,
        round(avg(checkins) OVER (PARTITION BY branch_id)) AS branch_avg
      FROM monthly
    )
    SELECT
      b.name       AS branch_name,
      w.branch_id,
      w.local_month,
      w.checkins,
      w.branch_avg,
      round(100.0 * w.checkins / NULLIF(w.branch_avg, 0), 1) AS pct_of_avg
    FROM   with_avg w
    JOIN   branches b ON b.branch_id = w.branch_id
    ORDER  BY pct_of_avg ASC NULLS LAST, w.branch_id, w.local_month
    LIMIT  20
  `,
};
