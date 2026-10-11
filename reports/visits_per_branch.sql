-- ============================================================
-- FILE: visits_per_branch.sql
-- GOAL: Count member visits per branch in calendar year 2024
--       (local time at each branch).
--       Returns one row per branch: branch_id, branch_name,
--       member_visits.
-- CONTEXT: Produced after data-quality investigation in
--       exploration/01–06.  Every counting decision is documented
--       inline below.
-- ============================================================

WITH

-- ── 1. DEDUPLICATION ────────────────────────────────────────────────────
-- At-least-once delivery from access devices produces duplicate
-- source_refs (RC1: 3,756 extra rows across all 24 devices).
-- Keep the FIRST-ingested copy: exploration/05 X2 showed that
-- re-delivered copies have event_ts set to the batch re-delivery
-- time rather than the original event time.
deduped AS (
  SELECT DISTINCT ON (source_ref) *
  FROM   events
  ORDER  BY source_ref, ingested_at ASC, event_id ASC
),

-- ── 2. SCOPE: registered members, access events, local year 2024 ────────
-- • Registered members only: member_ids absent from the members table
--   are test/service accounts (RC3).  They are excluded from visit
--   counts because they have no memberships and are not real members.
-- • Case-insensitive event_type: RC4 (D04-IN) sent "CHECK_IN" in
--   uppercase during Apr 8–15 2024.  lower() absorbs that variant
--   without hardcoding device ids or date ranges.
-- • Local year 2024: the year filter is applied at the check_in
--   timestamp converted to the branch's IANA timezone (business rule:
--   "days and months are calendar days in the time zone of the branch").
--   Filtering inside this CTE (before the window in step 3) prevents
--   out-of-scope events from distorting the pairing logic.
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

-- ── 3. PAIRING: look at what immediately follows each event ─────────────
-- The window is PARTITION BY member_id (not by branch) because a
-- member can only be in one place at a time.  The very next access
-- event for the member is the natural close of their current action.
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

-- ── 4. VISIT DEFINITION ─────────────────────────────────────────────────
-- Business rule: "a visit starts with a check_in at a branch's
-- entrance and ends with a check_out at the same branch's exit."
--
-- INCLUDED:
--   ✓ Complete pairs only: check_in whose immediately next event is
--     a check_out at the same branch.
--   ✓ Cancelled-member visits (293): RC5 means CRM cancellations
--     arrived up to 32 days late; the access-control system had no
--     knowledge of the cancellation at the time and granted entry.
--     The visit physically occurred.
--   ✓ Members 1031/1132 (RC6, no CRM history): valid rows in the
--     members table with verified access events.  The CRM gap is a
--     separate defect to fix.
--   ✓ Visits longer than 6 h (1,213 pairs): duration does not affect
--     whether a visit happened; it is counted as 1 visit.
--
-- EXCLUDED:
--   ✗ Unpaired check-ins (1,158 recheckins + 18 with no subsequent
--     event): the data does not prove these visits completed.
--     Counting them would mix "confirmed" with "possible" visits.
--   ✗ Cross-branch pairs (next check_out at a different branch, 2
--     cases): pairing is ambiguous; treated as unverifiable.
visits AS (
  SELECT branch_id
  FROM   with_next
  WHERE  etype       = 'check_in'
    AND  next_etype  = 'check_out'
    AND  next_branch = branch_id
)

-- ── 5. AGGREGATE ────────────────────────────────────────────────────────
-- LEFT JOIN ensures every branch appears in the result even if it
-- recorded zero qualifying visits (e.g. a branch that opened mid-year
-- might have no visits on a different database with sparse data).
SELECT
  b.branch_id,
  b.name              AS branch_name,
  count(v.branch_id)  AS member_visits
FROM   branches b
LEFT   JOIN visits v ON v.branch_id = b.branch_id
GROUP  BY b.branch_id, b.name
ORDER  BY b.branch_id;
