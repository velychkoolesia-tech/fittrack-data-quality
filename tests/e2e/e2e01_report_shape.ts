import type { Check } from '../../src/lib/types';
import { DEDUPED_FIRST_DELIVERY, REGISTERED_MEMBER } from '../../src/lib/sql';

// -- ============================================================
// -- CHECK: E2E01 – visits_per_branch has the right shape
// -- WHAT I'M TESTING: I am running the full visits_per_branch report
// --   logic inline and verifying its *structure* holds on any
// --   database: it returns exactly one row per branch, and the total
// --   visit count is greater than zero.
// -- WHY: This is the schema-portable, always-true half of an
// --   end-to-end report check.  A load that ingested nothing (total
// --   = 0) or a report that dropped/duplicated branches is broken on
// --   ANY database and must stop the run.  The dataset-specific
// --   volume band (is the number plausibly ~70k?) is intentionally
// --   NOT here — it lives in E2E03 as a warning, because a different
// --   database with the same schema can hold a legitimately different
// --   number of visits without anything being wrong.
// -- EXPECTED: 0 rows (one row per branch and a non-zero total).
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'E2E01',
  name: 'visits_per_branch returns one row per branch and a non-zero total',
  severity: 'blocking',
  sql: `
    WITH deduped AS (${DEDUPED_FIRST_DELIVERY}),
    access AS (
      SELECT e.member_id, e.event_id, lower(e.event_type) AS etype,
             e.event_ts, e.branch_id
      FROM   deduped e
      JOIN   branches b ON b.branch_id = e.branch_id
      WHERE  lower(e.event_type) IN ('check_in', 'check_out')
        AND  ${REGISTERED_MEMBER}
        AND  extract(year FROM e.event_ts AT TIME ZONE b.timezone) = 2024
    ),
    with_next AS (
      SELECT member_id, event_id, etype, event_ts, branch_id,
        lead(etype)     OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS ne,
        lead(branch_id) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS nb
      FROM access
    ),
    visits AS (
      SELECT branch_id
      FROM   with_next
      WHERE  etype = 'check_in' AND ne = 'check_out' AND nb = branch_id
    ),
    report AS (
      SELECT b.branch_id, count(v.branch_id) AS member_visits
      FROM   branches b
      LEFT   JOIN visits v ON v.branch_id = b.branch_id
      GROUP  BY b.branch_id
    ),
    summary AS (
      SELECT
        count(*)             AS branch_count,
        sum(member_visits)   AS total_visits,
        (SELECT count(*) FROM branches) AS expected_branches
      FROM report
    )
    SELECT branch_count, total_visits, expected_branches
    FROM   summary
    WHERE  branch_count  != expected_branches
        OR total_visits  IS NULL
        OR total_visits   = 0
  `,
};
