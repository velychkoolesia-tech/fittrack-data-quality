import type { Check } from '../lib/types';

// -- ============================================================
// -- CHECK: E2E01 – visits_per_branch total is within expected range
// -- WHAT I'M TESTING: I am running the full visits_per_branch
// --   report logic inline and verifying that the total visit count
// --   across all branches falls between $1 (min) and $2 (max).
// --   On this dataset the answer is 70,721.  Default bounds are
// --   50,000–200,000; tune them for the expected population.
// --   Also verifies the report returns exactly one row per branch.
// -- WHY: A corrupt data load could produce totals of 0 (no events
// --   ingested), a few hundred (only test data), or millions
// --   (dedup failed).  A range check on the final report output
// --   catches all of these with a single blocking assertion.
// -- EXPECTED: 0 rows (total within range and branch count correct).
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

const minVisits    = parseInt(process.env.MIN_TOTAL_VISITS    ?? '50000',  10);
const maxVisits    = parseInt(process.env.MAX_TOTAL_VISITS    ?? '200000', 10);

export const check: Check = {
  id: 'E2E01',
  name: `visits_per_branch total is between ${minVisits.toLocaleString()} and ${maxVisits.toLocaleString()}, one row per branch`,
  severity: 'blocking',
  kind: 'positive',
  params: [minVisits, maxVisits],
  sql: `
    WITH deduped AS (
      SELECT DISTINCT ON (source_ref) *
      FROM   events
      ORDER  BY source_ref, ingested_at ASC, event_id ASC
    ),
    access AS (
      SELECT e.member_id, e.event_id, lower(e.event_type) AS etype,
             e.event_ts, e.branch_id
      FROM   deduped e
      JOIN   branches b ON b.branch_id = e.branch_id
      WHERE  lower(e.event_type) IN ('check_in', 'check_out')
        AND  e.member_id IN (SELECT member_id FROM members)
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
    WHERE  branch_count != expected_branches
        OR total_visits  < $1
        OR total_visits  > $2
  `,
};
