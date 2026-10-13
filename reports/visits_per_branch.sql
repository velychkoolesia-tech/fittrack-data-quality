-- ============================================================
-- visits_per_branch.sql
-- One row per branch: member visits in 2024 (branch-local time).
-- Columns: branch_id, branch_name, member_visits.
-- Counting decisions are documented inline.
-- ============================================================

WITH

-- 1. De-duplicate. Devices deliver each event more than once (RC1).
--    Keep the first delivery: a re-delivered copy carries the batch
--    re-delivery time in event_ts, not the original scan time.
deduped AS (
  SELECT DISTINCT ON (source_ref) *
  FROM   events
  ORDER  BY source_ref, ingested_at ASC, event_id ASC
),

-- 2. Scope: registered members, access events, local year 2024.
--    - Registered members only: ids not in `members` are test/service
--      cards (RC3), not real members.
--    - lower(event_type): absorbs the uppercase "CHECK_IN" bug (RC4) by
--      pattern, without naming any device or date.
--    - 2024 is the report's fixed reporting period (ASSIGNMENT: "visits
--      in 2024") — a business constant, not a dataset quirk, so it holds
--      on any database with the same schema. Judged in the branch's
--      timezone (rule 5). Filtering here, before pairing, keeps
--      out-of-scope events from breaking the pairs.
access AS (
  SELECT
    e.member_id,
    e.event_id,
    lower(e.event_type) AS etype,
    e.event_ts,
    e.branch_id
  FROM   deduped  e
  JOIN   branches b ON b.branch_id = e.branch_id
  WHERE  lower(e.event_type) IN ('check_in', 'check_out')
    AND  e.member_id IN (SELECT member_id FROM members)
    AND  extract(year FROM e.event_ts AT TIME ZONE b.timezone) = 2024
),

-- 3. Pair each event with the member's next one. Partition by member
--    (a member is in one place at a time); their next access event is
--    the natural close of the current one.
with_next AS (
  SELECT
    member_id,
    event_id,
    etype,
    event_ts,
    branch_id,
    lead(etype)     OVER (PARTITION BY member_id
                          ORDER BY event_ts, event_id) AS next_etype,
    lead(branch_id) OVER (PARTITION BY member_id
                          ORDER BY event_ts, event_id) AS next_branch
  FROM access
),

-- 4. A visit = a check_in whose next event is a check_out at the same
--    branch (rule 3).
--    Included: cancelled members (RC5 — entry was granted, the visit
--      happened), members with no CRM history (RC6), and visits over 6h
--      (duration doesn't change that a visit occurred).
--    Excluded: unpaired check-ins (re-entries or lost check-outs — not
--      proven complete) and pairs that close at a different branch
--      (ambiguous).
visits AS (
  SELECT branch_id
  FROM   with_next
  WHERE  etype       = 'check_in'
    AND  next_etype  = 'check_out'
    AND  next_branch = branch_id
)

-- 5. Count per branch. LEFT JOIN so every branch appears, even with
--    zero visits (e.g. a branch that opened mid-year).
SELECT
  b.branch_id,
  b.name              AS branch_name,
  count(v.branch_id)  AS member_visits
FROM   branches b
LEFT   JOIN visits v ON v.branch_id = b.branch_id
GROUP  BY b.branch_id, b.name
ORDER  BY b.branch_id;
