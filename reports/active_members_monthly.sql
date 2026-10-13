-- ============================================================
-- FILE: active_members_monthly.sql
-- GOAL: For each month of 2024, how many members were active
--       (business rule 2).  One row per month, 2024-01 … 2024-12.
-- CONTEXT: Bonus report.  Same rules as visits_per_branch.sql — one
--       standalone Postgres 17 query, read-only, no custom views /
--       tables / functions, portable to a different database with the
--       same schema.  Counting decisions are documented inline.
-- ============================================================

WITH
-- ── Membership events that change active/cancelled state ────────────────
-- Business rule 2: a member is active in a month when their LATEST
-- membership event up to the end of that month is membership_started or
-- membership_reactivated.  Only these three event types move the
-- active/cancelled state, so tier_changed is excluded from the "latest
-- event" decision — a tier change happens while active and must not be
-- mistaken for a non-active state.
membership AS (
  SELECT
    e.member_id,
    lower(e.event_type) AS etype,
    e.event_ts,
    e.event_id,
    -- Rule 5: the month is the calendar month in the branch-local
    -- timezone of the branch where the event happened.  Every event
    -- (including CRM events) carries a branch_id, so this is well defined.
    to_char(e.event_ts AT TIME ZONE b.timezone, 'YYYY-MM') AS local_ym
  FROM   events   e
  JOIN   branches b ON b.branch_id = e.branch_id
  WHERE  lower(e.event_type) IN
         ('membership_started', 'membership_reactivated', 'membership_cancelled')
),
-- ── The 12 reporting months ─────────────────────────────────────────────
-- 2024 is the assignment's fixed reporting period (the same business
-- constant as the required report); the window is generated, not derived
-- from the data, so the report always means "the months of 2024".
months AS (
  SELECT to_char(gs, 'YYYY-MM') AS month
  FROM   generate_series('2024-01-01'::date, '2024-12-01'::date, interval '1 month') AS gs
),
-- ── Each member's state at the end of each month ────────────────────────
-- Membership history goes back to 2021, so a member's state at the end of
-- a 2024 month depends on ALL their events up to that month, not only
-- 2024 ones.  For each (month, member) keep the single latest membership
-- event on or before that month.  YYYY-MM strings compare chronologically.
state AS (
  SELECT DISTINCT ON (m.month, mb.member_id)
    m.month,
    mb.member_id,
    mb.etype AS latest_etype
  FROM   months     m
  JOIN   membership mb ON mb.local_ym <= m.month
  ORDER  BY m.month, mb.member_id, mb.event_ts DESC, mb.event_id DESC
)
-- ── Count actives per month ─────────────────────────────────────────────
-- LEFT JOIN from months guarantees all 12 rows appear even if a month had
-- zero actives.  Members with no membership events at all (e.g. profile
-- rows with no CRM history) never appear here — by rule 2 state comes from
-- events, so they cannot be counted active.
SELECT
  m.month,
  count(s.member_id) FILTER (
    WHERE s.latest_etype IN ('membership_started', 'membership_reactivated')
  ) AS active_members
FROM   months m
LEFT   JOIN state s ON s.month = m.month
GROUP  BY m.month
ORDER  BY m.month;
