import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: EC02 – visits that cross local midnight
// -- WHAT I'M TESTING: I am surfacing clean visit pairs where the
// --   check_in and check_out fall on different local calendar dates
// --   at the branch (i.e. the visit crossed midnight).  These are
// --   valid visits, but a report that groups by check_in date will
// --   place the whole visit in one day while a report that groups
// --   by check_out date will place it in the next day.
// -- WHY: Date-granularity reports (daily_visits) must handle this
// --   consistently.  Surfacing the count lets us document the
// --   decision rather than discover a discrepancy in production.
// --   Only visits ≤ 6 h are included; longer pairs are almost
// --   certainly unclosed-visit artefacts (a check_in paired with a
// --   check_out many days later), already counted in S3a.
// -- EXPECTED: Ideally 0 (branches close at 23:00, so a valid visit
// --   can only cross midnight if it starts very close to closing time
// --   and runs past midnight).  Any rows are worth documenting so the
// --   daily_visits report handles them consistently.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'EC02',
  name: 'Visits crossing local midnight (check_in and check_out on different local dates)',
  severity: 'warning',
  kind: 'edge-case',
  sql: `
    WITH deduped AS (
      SELECT DISTINCT ON (source_ref) *
      FROM events
      ORDER BY source_ref, ingested_at ASC, event_id ASC
    ),
    access AS (
      SELECT member_id, event_id, lower(event_type) AS etype, event_ts, branch_id
      FROM deduped
      WHERE lower(event_type) IN ('check_in', 'check_out')
        AND member_id IN (SELECT member_id FROM members)
    ),
    paired AS (
      SELECT
        a.member_id,
        a.branch_id,
        a.event_ts                                            AS checkin_ts,
        lead_ts                                               AS checkout_ts,
        b.timezone
      FROM (
        SELECT
          member_id, branch_id, event_ts,
          lead(etype)     OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_etype,
          lead(branch_id) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_branch,
          lead(event_ts)  OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_ts,
          etype
        FROM access
      ) a
      JOIN branches b ON b.branch_id = a.branch_id
      WHERE a.etype      = 'check_in'
        AND lead_etype   = 'check_out'
        AND lead_branch  = a.branch_id
    )
    SELECT
      member_id,
      branch_id,
      checkin_ts  AT TIME ZONE timezone AS checkin_local,
      checkout_ts AT TIME ZONE timezone AS checkout_local,
      checkout_ts - checkin_ts          AS duration
    FROM paired
    WHERE (checkin_ts  AT TIME ZONE timezone)::date
       != (checkout_ts AT TIME ZONE timezone)::date
      -- exclude unclosed-visit artefacts (paired with a distant check_out)
      AND checkout_ts - checkin_ts <= interval '6 hours'
    ORDER BY member_id, checkin_ts
  `,
};
