import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: E2E02 – each member's first cancellation is after first start
// -- WHAT I'M TESTING: I am checking that for every member who has
// --   both a membership_started and a membership_cancelled event,
// --   the earliest cancellation is strictly after the earliest
// --   start.  A cancellation at or before the start timestamp
// --   means the lifecycle is backwards—the member was cancelled
// --   before they ever joined, which is physically impossible.
// -- WHY: BR01 catches invalid state-machine transitions in sequence
// --   but does not check absolute timestamps.  It is possible to
// --   have a valid A→B→A transition where B happened before A in
// --   real time if two events share a timestamp or have a tiny
// --   clock skew.  This check catches that case end-to-end.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'E2E02',
  name: 'First membership_cancelled is always after first membership_started',
  severity: 'warning',
  sql: `
    WITH first_start AS (
      SELECT DISTINCT ON (member_id)
        member_id, event_ts AS started_ts
      FROM   events
      WHERE  lower(event_type) = 'membership_started'
      ORDER  BY member_id, event_ts ASC, event_id ASC
    ),
    first_cancel AS (
      SELECT DISTINCT ON (member_id)
        member_id, event_ts AS cancelled_ts
      FROM   events
      WHERE  lower(event_type) = 'membership_cancelled'
      ORDER  BY member_id, event_ts ASC, event_id ASC
    )
    SELECT
      s.member_id,
      s.started_ts,
      c.cancelled_ts,
      c.cancelled_ts - s.started_ts AS gap
    FROM   first_start  s
    JOIN   first_cancel c USING (member_id)
    WHERE  c.cancelled_ts <= s.started_ts
    ORDER  BY s.member_id
  `,
};
