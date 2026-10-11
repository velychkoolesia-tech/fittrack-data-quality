-- ============================================================
-- FILE: 06_recheck.sql
-- GOAL: I am re-running the five checks from 04_integrity.sql that used
--       the wrong dedup direction (ingested_at DESC = latest delivery).
--       X2 in 05_rootcause revealed that re-delivered copies have
--       event_ts stamped at the batch re-delivery time, not the original
--       event time.  The correct rule is to keep the FIRST delivery
--       (ingested_at ASC).  These are the corrected numbers for S2, S3a,
--       S3b, S4, S8, and S9.  S1, S5, S6, S7, S10, S11 are unaffected
--       (S1 never uses event_ts; S5–S7/S10–S11 query CRM or the members
--       table directly, which have no device duplicates).
-- CONTEXT: 04_integrity.sql ran all dedup CTEs with ingested_at DESC.
--       05_rootcause X2 showed the re-delivered copy has event_ts set
--       to the batch timestamp (e.g. 2024-10-20 07:21 UTC = ~03:21
--       local), creating 3,036 phantom off-hours events and distorting
--       visit pairing and double-scan counts.  The correct dedup is
--       ingested_at ASC (first delivery = original event_ts).
-- ============================================================

-- ============================================================
-- CHECK: S2-corrected – double scans with correct dedup
-- WHAT I'M TESTING: I am re-running the double-scan check from S2 with
--   the first-delivery dedup.  With the wrong dedup (DESC) the batch
--   re-delivery could put two check-ins for the same member within
--   seconds of each other (both re-delivered at the same batch time),
--   artificially inflating the within-1-min count.
-- WHY: The visit report must not count double-scans; the corrected
--   number tells us how many real hardware re-triggers exist.
-- EXPECTED: Equal to or lower than S2's 35 / 543 / 630.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S2-corrected: double scans (first-delivery dedup) ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
),
checkins AS (
    SELECT
        member_id,
        event_ts,
        lag(event_ts) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS prev_ts
    FROM deduped
    WHERE lower(event_type) = 'check_in'
      AND member_id IN (SELECT member_id FROM members)
)
SELECT
    count(*) FILTER (WHERE prev_ts IS NOT NULL
                     AND event_ts - prev_ts <= interval '1 minute')   AS within_1min,
    count(*) FILTER (WHERE prev_ts IS NOT NULL
                     AND event_ts - prev_ts <= interval '5 minutes')  AS within_5min,
    count(*) FILTER (WHERE prev_ts IS NOT NULL
                     AND event_ts - prev_ts <= interval '30 minutes') AS within_30min,
    count(*)                                                          AS total_checkins
FROM checkins;

-- ============================================================
-- CHECK: S3a-corrected – check-in outcomes with correct dedup
-- WHAT I'M TESTING: I am re-running the visit-pairing check from S3a.
--   With the wrong dedup the batch re-delivery created artificial
--   inverted sequences (check-out appeared before check-in in timestamp
--   order because the re-delivered check-in had a future event_ts),
--   inflating recheckin_no_checkout and possibly long_visit_over_6h.
-- WHY: The visit report's handling of unpaired check-ins depends on
--   these counts being accurate.
-- EXPECTED: recheckin_no_checkout and long_visit_over_6h lower than
--   S3a's 1,158 and 1,213; clean_pair share higher.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S3a-corrected: check-in outcomes (first-delivery dedup) ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
),
access AS (
    SELECT
        member_id,
        event_id,
        lower(event_type) AS etype,
        event_ts,
        branch_id
    FROM deduped
    WHERE lower(event_type) IN ('check_in','check_out')
      AND member_id IN (SELECT member_id FROM members)
),
with_next AS (
    SELECT
        etype,
        branch_id,
        event_ts,
        lead(etype)     OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS next_etype,
        lead(branch_id) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS next_branch,
        lead(event_ts)  OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS next_ts
    FROM access
)
SELECT
    CASE
        WHEN next_etype = 'check_out' AND next_branch = branch_id
             AND next_ts - event_ts <= interval '6 hours'  THEN 'clean_pair'
        WHEN next_etype = 'check_out' AND next_branch = branch_id
             AND next_ts - event_ts >  interval '6 hours'  THEN 'long_visit_over_6h'
        WHEN next_etype = 'check_out' AND next_branch != branch_id  THEN 'checkout_diff_branch'
        WHEN next_etype = 'check_in'                                THEN 'recheckin_no_checkout'
        WHEN next_etype IS NULL                                      THEN 'no_subsequent_event'
        ELSE 'other'
    END AS outcome,
    count(*) AS n
FROM with_next
WHERE etype = 'check_in'
GROUP BY 1
ORDER BY 2 DESC;

-- ============================================================
-- CHECK: S3b-corrected – orphan and stacked check-outs with correct dedup
-- WHAT I'M TESTING: I am re-running S3b.  With the wrong dedup a
--   re-delivered check-out could appear to immediately follow a
--   re-delivered check-in (both at batch time), or a re-delivered
--   check-in could appear after the matching check-out, creating
--   artificial orphan and stacked counts.
-- WHY: stacked_checkout and orphan_first_ever are the mirror of
--   recheckin_no_checkout; the same distortion affects both.
-- EXPECTED: stacked_checkout lower than S3b's 278; orphan_first_ever
--   equal to or lower than 6.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S3b-corrected: orphan and stacked check-outs (first-delivery dedup) ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
),
access AS (
    SELECT
        member_id,
        event_id,
        lower(event_type) AS etype,
        event_ts,
        branch_id
    FROM deduped
    WHERE lower(event_type) IN ('check_in','check_out')
      AND member_id IN (SELECT member_id FROM members)
),
with_prev AS (
    SELECT
        etype,
        branch_id,
        lag(etype)     OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS prev_etype,
        lag(branch_id) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS prev_branch
    FROM access
)
SELECT
    count(*) FILTER (WHERE etype = 'check_out'
                     AND prev_etype IS NULL)                      AS orphan_first_ever,
    count(*) FILTER (WHERE etype = 'check_out'
                     AND prev_etype = 'check_out')                AS stacked_checkout,
    count(*) FILTER (WHERE etype = 'check_out'
                     AND prev_etype = 'check_in'
                     AND prev_branch != branch_id)                AS paired_diff_branch,
    count(*) FILTER (WHERE etype = 'check_out'
                     AND prev_etype = 'check_in'
                     AND prev_branch = branch_id)                 AS properly_paired,
    count(*) FILTER (WHERE etype = 'check_out')                   AS total_checkouts
FROM with_prev;

-- ============================================================
-- CHECK: S4-corrected – membership state at check-in with correct dedup
-- WHAT I'M TESTING: I am re-running S4.  A re-delivered check-in with
--   event_ts set to the batch re-delivery time (e.g. Oct 2024) lands in
--   a different part of the member's CRM timeline than the original
--   event (e.g. Oct 2024 check-in vs original Jul 2024 check-in), so
--   the CRM state looked up via LATERAL could differ.
-- WHY: The 295 cancelled-member check-ins from S4 may be partly or
--   wholly inflated by events with wrong timestamps landing after the
--   member's cancellation date.
-- EXPECTED: 'membership_cancelled' count equal to or lower than S4's
--   295; 'no_prior_crm_event' stays at 125 (those members have no CRM
--   events at all, so dedup direction cannot change their state).
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S4-corrected: membership state at check-in (first-delivery dedup) ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
),
checkins AS (
    SELECT member_id, event_ts
    FROM deduped
    WHERE lower(event_type) = 'check_in'
      AND member_id IN (SELECT member_id FROM members)
)
SELECT
    COALESCE(crm.last_state, 'no_prior_crm_event') AS membership_state_at_checkin,
    count(*)                                        AS n
FROM checkins ci
LEFT JOIN LATERAL (
    SELECT lower(event_type) AS last_state
    FROM events
    WHERE member_id = ci.member_id
      AND lower(event_type) IN ('membership_started','membership_reactivated','membership_cancelled')
      AND event_ts <= ci.event_ts
    ORDER BY event_ts DESC
    LIMIT 1
) crm ON true
GROUP BY 1
ORDER BY 2 DESC;

-- ============================================================
-- CHECK: S8-corrected – friend visits outside open visit with correct dedup
-- WHAT I'M TESTING: I am re-running S8.  A re-delivered friend_visit
--   with event_ts = batch time could appear to happen long after the
--   member's check-out (visit already closed), inflating
--   outside_open_visit.  Symmetrically, a re-delivered check-in with
--   batch time could make the member appear to be "in" at a time they
--   were not, reducing outside_open_visit.
-- WHY: 73 outside-open-visit friend_visits from S8 may be partly
--   inflated; the corrected number feeds directly into the friend-
--   allowance report.
-- EXPECTED: outside_open_visit equal to or lower than S8's 73.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S8-corrected: friend visits outside open visit (first-delivery dedup) ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
),
fv AS (
    SELECT member_id, event_ts, branch_id
    FROM deduped
    WHERE lower(event_type) = 'friend_visit'
      AND member_id IN (SELECT member_id FROM members)
),
access AS (
    SELECT member_id, event_id, lower(event_type) AS etype, event_ts, branch_id
    FROM deduped
    WHERE lower(event_type) IN ('check_in','check_out')
      AND member_id IN (SELECT member_id FROM members)
)
SELECT
    count(*)                                                   AS total_friend_visits,
    count(*) FILTER (WHERE last_ev.etype IS NULL
                     OR   last_ev.etype = 'check_out')        AS outside_open_visit
FROM fv
LEFT JOIN LATERAL (
    SELECT etype
    FROM access
    WHERE member_id = fv.member_id
      AND branch_id  = fv.branch_id
      AND event_ts  <= fv.event_ts
    ORDER BY event_ts DESC, event_id DESC
    LIMIT 1
) last_ev ON true;

-- ============================================================
-- CHECK: S9-corrected – off-hours event share per device with correct dedup
-- WHAT I'M TESTING: I am re-running S9.  The batch re-delivery
--   timestamps (~07:21 UTC = 00:21–03:21 local) put 3,036 events into
--   the off-hours window when the wrong (latest) copy was kept.  With
--   the first-delivery copy those events have their original timestamps
--   and fall within opening hours.
-- WHY: S9 reported ~2 % off-hours on every device; the corrected result
--   shows only D07-IN (Mission Bay) with a real off-hours excess from
--   the RC2 clock shift (Jun–Aug 2024).  All other devices should be at
--   or near 0 %.
-- EXPECTED: D07-IN ~1.7 % (172 events); all other devices ~0 %.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S9-corrected: off-hours event share per device (first-delivery dedup) ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
)
SELECT
    e.device_id,
    b.name                                                              AS branch_name,
    d.kind,
    count(*)                                                            AS total_events,
    count(*) FILTER (
        WHERE (e.event_ts AT TIME ZONE b.timezone)::time
              NOT BETWEEN b.opens_at AND b.closes_at
    )                                                                   AS off_hours_events,
    round(
        100.0 * count(*) FILTER (
            WHERE (e.event_ts AT TIME ZONE b.timezone)::time
                  NOT BETWEEN b.opens_at AND b.closes_at
        ) / NULLIF(count(*), 0), 1
    )                                                                   AS pct_off_hours
FROM deduped e
JOIN devices  d USING (device_id)
JOIN branches b ON b.branch_id = e.branch_id
WHERE e.device_id IS NOT NULL AND e.device_id != ''
GROUP BY e.device_id, b.name, d.kind
ORDER BY pct_off_hours DESC NULLS LAST;
