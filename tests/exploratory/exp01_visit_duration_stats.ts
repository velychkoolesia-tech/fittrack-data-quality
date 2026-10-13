import type { Check } from '../../src/lib/types';
import { DEDUPED_FIRST_DELIVERY, REGISTERED_MEMBER } from '../../src/lib/sql';

// -- ============================================================
// -- CHECK: EXP01 – visit duration distribution (exploratory)
// -- WHAT I'M TESTING: I am computing the distribution of clean-pair
// --   visit durations across five buckets.  This is not a
// --   pass/fail check; it surfaces the shape of the data so that
// --   anomalies (too many very short or very long visits) are
// --   visible without needing to open the database manually.
// -- WHY: A spike in the "< 5 min" bucket suggests hardware
// --   double-triggers or test scans.  A spike in the "> 6 h" bucket
// --   suggests lost check-outs.  Both affect the visits report.
// -- EXPECTED: N/A – exploratory, always displays stats.
// -- SEVERITY IF IT FAILS: N/A
// -- ============================================================

export const check: Check = {
  id: 'EXP01',
  name: 'Visit duration distribution',
  severity: 'warning',
  kind: 'exploratory',
  sql: `
    WITH deduped AS (${DEDUPED_FIRST_DELIVERY}),
    access AS (
      SELECT member_id, event_id, lower(event_type) AS etype, event_ts, branch_id
      FROM deduped
      WHERE lower(event_type) IN ('check_in', 'check_out')
        AND ${REGISTERED_MEMBER}
    ),
    durations AS (
      SELECT lead_ts - event_ts AS dur
      FROM (
        SELECT
          event_ts,
          lead(etype)     OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_etype,
          lead(branch_id) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_branch,
          lead(event_ts)  OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_ts,
          branch_id, etype
        FROM access
      ) w
      WHERE etype = 'check_in' AND lead_etype = 'check_out' AND lead_branch = branch_id
    )
    SELECT
      count(*) FILTER (WHERE dur <  interval '5 minutes')                          AS under_5min,
      count(*) FILTER (WHERE dur >= interval '5 minutes'
                         AND dur <  interval '1 hour')                             AS min5_to_1h,
      count(*) FILTER (WHERE dur >= interval '1 hour'
                         AND dur <  interval '3 hours')                            AS h1_to_3h,
      count(*) FILTER (WHERE dur >= interval '3 hours'
                         AND dur <= interval '6 hours')                            AS h3_to_6h,
      count(*) FILTER (WHERE dur >  interval '6 hours')                            AS over_6h,
      count(*)                                                                     AS total_paired,
      round(extract(epoch FROM avg(dur)) / 60, 1)                                 AS avg_duration_min
    FROM durations
  `,
};
