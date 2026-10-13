import type { Check } from '../../src/lib/types';
import { DEDUPED_FIRST_DELIVERY } from '../../src/lib/sql';

// -- ============================================================
// -- CHECK: EC05 – events at exactly branch closing time are within hours
// -- WHAT I'M TESTING: I am checking that events timestamped at
// --   exactly the branch closes_at time (e.g. 23:00:00 local) are
// --   classified as within opening hours by the BETWEEN expression:
// --     (event_ts AT TIME ZONE tz)::time BETWEEN opens_at AND closes_at
// --   This is the symmetric boundary check to EC01 (opens_at).
// -- WHY: If BETWEEN excluded the upper bound, every check_out at
// --   exactly 23:00:00 would be counted as an off-hours event.
// --   Members who leave at exactly closing time would be wrongly
// --   flagged as rule violations.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'EC05',
  name: 'Events at exactly branch closing time are classified as within hours',
  severity: 'blocking',
  sql: `
    WITH deduped AS (${DEDUPED_FIRST_DELIVERY})
    SELECT e.event_id, e.event_type, e.event_ts, b.name AS branch_name
    FROM   deduped e
    JOIN   branches b ON b.branch_id = e.branch_id
    WHERE  lower(e.event_type) IN ('check_in', 'check_out', 'friend_visit')
      -- event is at exactly the branch closing time
      AND  (e.event_ts AT TIME ZONE b.timezone)::time = b.closes_at
      -- but our off-hours expression would call it off-hours
      AND  (e.event_ts AT TIME ZONE b.timezone)::time
           NOT BETWEEN b.opens_at AND b.closes_at
    ORDER  BY e.event_id
  `,
};
