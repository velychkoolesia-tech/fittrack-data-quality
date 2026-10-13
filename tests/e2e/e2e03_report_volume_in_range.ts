import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: E2E03 – visits_per_branch total is in a plausible band
// -- WHAT I'M TESTING: I am running the full visits_per_branch report
// --   logic inline and checking the grand total against a plausible
// --   volume band ($1 min, $2 max).  On this dataset the total is
// --   70,721; default bounds are 50,000–200,000.
// -- WHY: A total that is suddenly a few hundred (only test data left)
// --   or in the millions (de-dup silently failed) is worth a human
// --   look even when the report's shape is fine (E2E01 covers shape).
// -- SEVERITY IF IT FAILS: warning.  The band is tuned to THIS
// --   dataset's population, so a different database with the same
// --   schema can legitimately fall outside it.  Reported as a warning
// --   so volume differences never cause a false *blocking* failure;
// --   tune the bounds via MIN_TOTAL_VISITS / MAX_TOTAL_VISITS.
// -- EXPECTED: 0 rows (total within the band).
// -- ============================================================

const minVisits = parseInt(process.env.MIN_TOTAL_VISITS ?? '50000',  10);
const maxVisits = parseInt(process.env.MAX_TOTAL_VISITS ?? '200000', 10);

export const check: Check = {
  id: 'E2E03',
  name: `visits_per_branch total is between ${minVisits.toLocaleString()} and ${maxVisits.toLocaleString()}`,
  severity: 'warning',
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
    )
    SELECT sum(cnt) AS total_visits
    FROM (
      SELECT count(v.branch_id) AS cnt
      FROM   branches b
      LEFT   JOIN visits v ON v.branch_id = b.branch_id
      GROUP  BY b.branch_id
    ) report
    HAVING sum(cnt) < $1 OR sum(cnt) > $2
  `,
};
