import type { Check } from '../../src/lib/types';
import { DEDUPED_FIRST_DELIVERY, REGISTERED_MEMBER } from '../../src/lib/sql';

// -- ============================================================
// -- CHECK: EXP02 – members with unusually high monthly visit counts
// -- WHAT I'M TESTING: I am listing the top 10 members by visit
// --   count in any single local calendar month.  More than ~30
// --   visits in a month (roughly once a day) is plausible for a
// --   regular member; substantially higher may indicate test cards
// --   or a scanning glitch that is creating phantom check-ins.
// -- WHY: High-frequency members inflate branch visit totals and
// --   may distort the active-members and friend-allowance reports
// --   if they are not genuine.
// -- EXPECTED: N/A – exploratory, always displays top 10.
// -- SEVERITY IF IT FAILS: N/A
// -- ============================================================

export const check: Check = {
  id: 'EXP02',
  name: 'Highest single-month check-in count per member',
  severity: 'info',
  sql: `
    WITH deduped AS (${DEDUPED_FIRST_DELIVERY}),
    monthly AS (
      SELECT
        e.member_id,
        to_char(e.event_ts AT TIME ZONE b.timezone, 'YYYY-MM') AS local_month,
        count(*) AS checkin_count
      FROM deduped e
      JOIN branches b ON b.branch_id = e.branch_id
      WHERE lower(e.event_type) = 'check_in'
        AND ${REGISTERED_MEMBER}
      GROUP BY e.member_id, local_month
    )
    SELECT member_id, local_month, checkin_count
    FROM monthly
    ORDER BY checkin_count DESC
    LIMIT 10
  `,
};
