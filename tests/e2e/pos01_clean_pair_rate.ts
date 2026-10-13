import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: POS01 – at least 90 % of check-ins are clean pairs
// -- WHAT I'M TESTING: I am verifying that the vast majority of
// --   check-ins by registered members are followed by a matching
// --   check-out at the same branch within 6 hours.  This is a
// --   positive health check: if the rate drops below 90 % the
// --   visit report becomes too unreliable to publish.
// -- WHY: The visit report depends on paired events.  A low pair
// --   rate indicates a systemic access-control failure (devices
// --   stopped sending check-outs) rather than a data quality edge
// --   case.
// -- EXPECTED: 0 rows (clean-pair rate ≥ 90 %).
// -- SEVERITY IF IT FAILS: warning.  The 90 % threshold is a judgement
// --   tuned to this dataset, so a different database with the same
// --   schema could legitimately sit below it without anything being
// --   broken.  Reported as a warning so a volume/mix difference does
// --   not produce a false *blocking* failure on another database.
// -- ============================================================

export const check: Check = {
  id: 'POS01',
  name: 'Clean visit pair rate is at least 90 %',
  severity: 'warning',
  kind: 'positive',
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
    outcomes AS (
      SELECT
        count(*) FILTER (
          WHERE etype = 'check_in'
            AND lead_etype = 'check_out'
            AND lead_branch = branch_id
            AND lead_ts - event_ts <= interval '6 hours'
        )                       AS clean_pairs,
        count(*) FILTER (
          WHERE etype = 'check_in'
        )                       AS total_checkins
      FROM (
        SELECT
          etype, branch_id, event_ts,
          lead(etype)     OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_etype,
          lead(branch_id) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_branch,
          lead(event_ts)  OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS lead_ts
        FROM access
      ) w
    )
    SELECT
      clean_pairs,
      total_checkins,
      round(100.0 * clean_pairs / NULLIF(total_checkins, 0), 1) AS pct_clean
    FROM outcomes
    WHERE 100.0 * clean_pairs / NULLIF(total_checkins, 0) < 90
  `,
};
