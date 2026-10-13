-- ============================================================
-- active_members_monthly.sql   (bonus)
-- One row per month of 2024: how many members are active (rule 2).
-- Columns: month (YYYY-MM), active_members.
-- Same rules as visits_per_branch.sql: one standalone query, read-only,
-- no custom objects, portable to any database with the same schema.
-- ============================================================

WITH

-- 1. Membership events that set active/cancelled state. Only these three
--    change it, so tier_changed is excluded (a tier change happens while
--    active and must not look like a non-active state). Month is the
--    branch-local calendar month (rule 5); every event carries a
--    branch_id, so this is always defined.
membership AS (
  SELECT
    e.member_id,
    lower(e.event_type) AS etype,
    e.event_ts,
    e.event_id,
    to_char(e.event_ts AT TIME ZONE b.timezone, 'YYYY-MM') AS local_ym
  FROM   events   e
  JOIN   branches b ON b.branch_id = e.branch_id
  WHERE  lower(e.event_type) IN
         ('membership_started', 'membership_reactivated', 'membership_cancelled')
),

-- 2. The 12 reporting months. 2024 is the report's fixed period
--    (ASSIGNMENT), generated not derived — portable to any dataset.
months AS (
  SELECT to_char(gs, 'YYYY-MM') AS month
  FROM   generate_series('2024-01-01'::date, '2024-12-01'::date, interval '1 month') AS gs
),

-- 3. State at each month-end. History goes back to 2021, so consider all
--    events up to that month; keep the latest per (month, member).
--    YYYY-MM strings compare chronologically.
state AS (
  SELECT DISTINCT ON (m.month, mb.member_id)
    m.month,
    mb.member_id,
    mb.etype AS latest_etype
  FROM   months     m
  JOIN   membership mb ON mb.local_ym <= m.month
  ORDER  BY m.month, mb.member_id, mb.event_ts DESC, mb.event_id DESC
)

-- 4. Count actives per month. LEFT JOIN so all 12 months show. Members
--    with no membership events never appear — by rule 2 state comes from
--    events (a known gap: RC6 in DATA_QUALITY.md).
SELECT
  m.month,
  count(s.member_id) FILTER (
    WHERE s.latest_etype IN ('membership_started', 'membership_reactivated')
  ) AS active_members
FROM   months m
LEFT   JOIN state s ON s.month = m.month
GROUP  BY m.month
ORDER  BY m.month;
