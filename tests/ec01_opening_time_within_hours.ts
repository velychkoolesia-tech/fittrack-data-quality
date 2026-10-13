import type { Check } from '../src/lib/types';

// -- ============================================================
// -- CHECK: EC01 – events at exactly branch opening time are within hours
// -- WHAT I'M TESTING: I am verifying that events timestamped at
// --   exactly the branch opens_at time (e.g. 05:00:00 local) are
// --   classified as within opening hours, not off-hours.  This
// --   confirms that the BETWEEN operator is inclusive on both ends
// --   in our off-hours logic:
// --     (event_ts AT TIME ZONE tz)::time BETWEEN opens_at AND closes_at
// -- WHY: If BETWEEN were exclusive, events at exactly 05:00:00
// --   would silently appear as off-hours violations in BR and in the
// --   visits report, under-counting valid early-morning visits.
// -- EXPECTED: 0 rows (no event at exactly opens_at is classified
// --   as off-hours by the BETWEEN expression).
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'EC01',
  name: 'Events at exactly branch opening time are classified as within hours',
  severity: 'blocking',
  kind: 'edge-case',
  sql: `
    WITH deduped AS (
      SELECT DISTINCT ON (source_ref) *
      FROM events
      ORDER BY source_ref, ingested_at ASC, event_id ASC
    )
    SELECT e.event_id, e.event_type, e.event_ts, b.name AS branch_name
    FROM deduped e
    JOIN branches b ON b.branch_id = e.branch_id
    WHERE lower(e.event_type) IN ('check_in', 'check_out', 'friend_visit')
      -- event is at exactly the branch opening time
      AND (e.event_ts AT TIME ZONE b.timezone)::time = b.opens_at
      -- but our off-hours expression would call it off-hours
      AND (e.event_ts AT TIME ZONE b.timezone)::time
          NOT BETWEEN b.opens_at AND b.closes_at
    ORDER BY e.event_id
  `,
};
