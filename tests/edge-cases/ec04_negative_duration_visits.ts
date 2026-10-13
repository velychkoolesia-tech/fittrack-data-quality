import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: EC04 – no complete visit pair has zero or negative duration
// -- WHAT I'M TESTING: I am checking that for every complete visit
// --   pair (check_in + check_out at the same branch) the check_out
// --   event_ts is strictly after the check_in event_ts.  A pair
// --   where check_out ≤ check_in indicates a clock error on one of
// --   the two devices (analogous to RC2 but between entrance and
// --   exit of the same branch).
// -- WHY: A negative-duration visit is counted as 1 visit in the
// --   report but is physically impossible, so it is either a data
// --   error or a timestamp manipulation.  It would also produce a
// --   misleading average duration in EXP01.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'EC04',
  name: 'All complete visit pairs have strictly positive duration (check_out after check_in)',
  severity: 'blocking',
  kind: 'edge-case',
  sql: `
    WITH deduped AS (
      SELECT DISTINCT ON (source_ref) *
      FROM   events
      ORDER  BY source_ref, ingested_at ASC, event_id ASC
    ),
    access AS (
      SELECT member_id, event_id, lower(event_type) AS etype, event_ts, branch_id
      FROM   deduped
      WHERE  lower(event_type) IN ('check_in', 'check_out')
        AND  member_id IN (SELECT member_id FROM members)
    ),
    with_next AS (
      SELECT
        member_id, branch_id, event_ts AS ci_ts,
        lead(etype)     OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS ne,
        lead(branch_id) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS nb,
        lead(event_ts)  OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS co_ts,
        etype
      FROM access
    )
    SELECT member_id, branch_id, ci_ts, co_ts, co_ts - ci_ts AS duration
    FROM   with_next
    WHERE  etype = 'check_in'
      AND  ne    = 'check_out'
      AND  nb    = branch_id
      AND  co_ts <= ci_ts
    ORDER  BY member_id, ci_ts
  `,
};
