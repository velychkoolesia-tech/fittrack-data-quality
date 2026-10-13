-- ============================================================
-- friend_allowance_monthly.sql   (bonus)
-- One row per month of 2024: the average share of the monthly friend
-- allowance used by members who visited that month, as a percentage
-- with one decimal.  Columns: month (YYYY-MM), avg_utilization_pct.
-- Definition (ASSIGNMENT): for each member who visited at least once in
-- the month, take their friend visits that month (capped at their
-- allowance) / allowance; average across those members.
-- Same rules as visits_per_branch.sql (standalone, read-only, portable).
-- ============================================================

WITH

-- 1. De-duplicate first delivery (RC1) — the front-desk tablet that
--    records friend_visit also re-delivers each event.
deduped AS (
  SELECT DISTINCT ON (source_ref) *
  FROM   events
  ORDER  BY source_ref, ingested_at ASC, event_id ASC
),

-- 2. Tag every event with its branch-local month (rule 5).
ev AS (
  SELECT
    d.member_id,
    lower(d.event_type) AS etype,
    d.event_ts,
    d.event_id,
    d.details,
    to_char(d.event_ts AT TIME ZONE b.timezone, 'YYYY-MM') AS local_ym
  FROM   deduped  d
  JOIN   branches b ON b.branch_id = d.branch_id
),

-- 3. The 12 reporting months (2024, the report's fixed period).
months AS (
  SELECT to_char(gs, 'YYYY-MM') AS month
  FROM   generate_series('2024-01-01'::date, '2024-12-01'::date, interval '1 month') AS gs
),

-- 4. Population: registered members who visited (>=1 check_in) that
--    month — a friend can only enter with the member present.
--    Registered-only drops test/service cards (RC3).
visited AS (
  SELECT DISTINCT ev.local_ym AS month, ev.member_id
  FROM   ev
  WHERE  ev.etype = 'check_in'
    AND  ev.local_ym LIKE '2024-%'
    AND  ev.member_id IN (SELECT member_id FROM members)
),

-- 5. Friend visits each member brought, per month.
friends AS (
  SELECT ev.local_ym AS month, ev.member_id, count(*) AS fv
  FROM   ev
  WHERE  ev.etype = 'friend_visit'
  GROUP  BY ev.local_ym, ev.member_id
),

-- 6. Tier-setting events, tagged with the tier they set.
tier_events AS (
  SELECT
    ev.member_id, ev.event_ts, ev.event_id, ev.local_ym,
    CASE ev.etype WHEN 'tier_changed' THEN ev.details->>'to'
                  ELSE                      ev.details->>'tier' END AS tier
  FROM   ev
  WHERE  ev.etype IN ('membership_started', 'membership_reactivated', 'tier_changed')
),

-- 7. Each visiting member's tier as of month-end = latest tier event up
--    to that month (rule 4; history back to 2021). NULLS LAST so a real
--    event beats "none".
tier_asof AS (
  SELECT DISTINCT ON (v.month, v.member_id)
    v.month, v.member_id, te.tier
  FROM   visited v
  LEFT   JOIN tier_events te
         ON te.member_id = v.member_id AND te.local_ym <= v.month
  ORDER  BY v.month, v.member_id, te.event_ts DESC NULLS LAST, te.event_id DESC
),

-- 8. Utilisation per member/month = min(friends, allowance) / allowance.
--    Allowance from the event-derived tier, falling back to the members
--    snapshot for the rare no-history member (RC6); unknown tier dropped.
--    A visitor who brought no friends counts as 0 %.
per_member AS (
  SELECT
    ta.month,
    least(COALESCE(f.fv, 0), al.allowance)::numeric / al.allowance AS utilization
  FROM   tier_asof ta
  JOIN   members mem ON mem.member_id = ta.member_id
  LEFT   JOIN friends f ON f.member_id = ta.member_id AND f.month = ta.month
  CROSS  JOIN LATERAL (
    SELECT CASE lower(COALESCE(ta.tier, mem.membership_tier))
             WHEN 'basic'    THEN 2
             WHEN 'standard' THEN 3
             WHEN 'premium'  THEN 8
           END AS allowance
  ) AS al
  WHERE  al.allowance IS NOT NULL
)

-- 9. Average per month (LEFT JOIN keeps months with no visitors at 0.0).
SELECT
  m.month,
  round(COALESCE(avg(pm.utilization) * 100, 0), 1) AS avg_utilization_pct
FROM   months m
LEFT   JOIN per_member pm ON pm.month = m.month
GROUP  BY m.month
ORDER  BY m.month;
