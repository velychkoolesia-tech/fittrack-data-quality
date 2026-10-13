-- ============================================================
-- FILE: friend_allowance_monthly.sql
-- GOAL: For each month of 2024, the average share of their monthly friend
--       allowance that visiting members used, as a percentage with one
--       decimal.  One row per month, 2024-01 … 2024-12.
-- CONTEXT: Bonus report.  Same rules as visits_per_branch.sql.
--       Definition (assignment): for every member who visited at least
--       once in the month, take the friend visits they brought that month
--       (counting at most their allowance) divided by their allowance;
--       average across those members, as a percentage with one decimal.
-- ============================================================

WITH
-- ── De-duplicate first delivery ─────────────────────────────────────────
-- RC1: every device delivers each event more than once, including the
-- front-desk tablet that records friend_visit.  Keep the first delivery.
deduped AS (
  SELECT DISTINCT ON (source_ref) *
  FROM   events
  ORDER  BY source_ref, ingested_at ASC, event_id ASC
),
-- ── Every event tagged with its branch-local month (rule 5) ─────────────
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
-- ── The 12 reporting months (2024, the fixed business period) ───────────
months AS (
  SELECT to_char(gs, 'YYYY-MM') AS month
  FROM   generate_series('2024-01-01'::date, '2024-12-01'::date, interval '1 month') AS gs
),
-- ── Population: registered members who visited at least once in the month
-- "Visited" = at least one check_in that month.  A friend can only enter
-- together with the member, so a check-in is the signal the member was
-- present and could bring friends.  Registered-members-only drops the
-- test/service cards (RC3).
visited AS (
  SELECT DISTINCT ev.local_ym AS month, ev.member_id
  FROM   ev
  WHERE  ev.etype = 'check_in'
    AND  ev.local_ym LIKE '2024-%'
    AND  ev.member_id IN (SELECT member_id FROM members)
),
-- ── Friend visits a member brought, per month ───────────────────────────
friends AS (
  SELECT ev.local_ym AS month, ev.member_id, count(*) AS fv
  FROM   ev
  WHERE  ev.etype = 'friend_visit'
  GROUP  BY ev.local_ym, ev.member_id
),
-- ── Tier-setting events, tagged with the tier they set ──────────────────
tier_events AS (
  SELECT
    ev.member_id,
    ev.event_ts,
    ev.event_id,
    ev.local_ym,
    CASE ev.etype
      WHEN 'tier_changed' THEN ev.details->>'to'
      ELSE                     ev.details->>'tier'   -- started / reactivated
    END AS tier
  FROM   ev
  WHERE  ev.etype IN ('membership_started', 'membership_reactivated', 'tier_changed')
),
-- ── Each visiting member's tier as of the end of the month ──────────────
-- Rule 4: allowance depends on the member's tier IN THAT MONTH.  Take the
-- latest tier-setting event on or before the month (events go back to
-- 2021).  NULLS LAST so a real event is always preferred over "none".
tier_asof AS (
  SELECT DISTINCT ON (v.month, v.member_id)
    v.month,
    v.member_id,
    te.tier
  FROM   visited v
  LEFT   JOIN tier_events te
         ON te.member_id = v.member_id AND te.local_ym <= v.month
  ORDER  BY v.month, v.member_id, te.event_ts DESC NULLS LAST, te.event_id DESC
),
-- ── Per member per month: utilisation = min(friends, allowance)/allowance
-- Allowance comes from the event-derived tier; for the rare member with no
-- tier history at all (RC6) fall back to the members snapshot so they are
-- not silently dropped.  A member with no derivable tier either way has no
-- allowance to divide by and is excluded.  Non-visiting months contribute
-- nothing; a visiting member who brought no friends counts as 0 %.
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
-- ── One row per month (LEFT JOIN keeps months with no visitors at 0.0) ──
SELECT
  m.month,
  round(COALESCE(avg(pm.utilization) * 100, 0), 1) AS avg_utilization_pct
FROM   months m
LEFT   JOIN per_member pm ON pm.month = m.month
GROUP  BY m.month
ORDER  BY m.month;
