-- ============================================================
-- FILE: 05_rootcause.sql
-- GOAL: I am drilling into four open questions from 03–04: (X1) which
--       content column(s) differ within duplicate groups—this decides
--       the dedup rule; (X2) five concrete example groups; (X3) the
--       D07-IN clock-shift scope by month and its effect on SF visit
--       ordering; (X4) the universal ~2 % off-hours floor broken down by
--       month, member type, and top offenders; (X5) test accounts in
--       detail by branch, event type, and off-hours activity.
-- CONTEXT: From 01–04: all 24 devices produce duplicate source_refs,
--          3,036 groups have differing content (RC1); D07-IN timestamps
--          are ~3 h ahead Jun–Aug 2024 (RC2); test accounts 990001 and
--          990002 appear on all branches (RC3); D02-OUT is missing 27
--          exit events (RC8); every device shows ~2 % off-hours events
--          with no single identified cause (open after S9); 295 check-ins
--          happened while the member was cancelled (S4); 49 stale status
--          rows in members (S7).
-- NOTE ON DEDUP: X1a/X1b/X2 use raw events (no dedup needed—they are
--          counting duplicate groups themselves).  X3a uses raw events
--          to capture all D07-IN deliveries including duplicates.  All
--          other checks deduplicate by keeping the FIRST-ingested copy
--          (ORDER BY ingested_at ASC).  X2 revealed that re-delivered
--          copies have event_ts stamped at the moment of re-delivery, so
--          "keep latest" gives wrong timestamps.  Using ASC eliminates
--          the spurious off-hours floor (3,036 wrong timestamps → correct
--          original timestamps, all within hours).
-- ============================================================

-- ============================================================
-- CHECK: X1a – which content column(s) differ within duplicate groups
-- WHAT I'M TESTING: I am counting, across all duplicate source_ref
--   groups, how many have each content column (member_id, event_type,
--   event_ts, branch_id, device_id, details) taking more than one
--   distinct value.  'all_identical' groups differ only in ingested_at,
--   meaning the extra copy is a pure at-least-once re-delivery.
-- WHY: The dedup rule (step 1 of the plan) depends on this.  If event_ts
--   differs, "keep latest ingested" may not give the correct timestamp.
--   If member_id differs, one copy has the wrong member.
-- EXPECTED: Most groups are all_identical (pure retries).  Any column
--   that differs at scale becomes the deciding factor for the dedup rule.
-- SEVERITY IF IT FAILS: N/A (investigation)
-- ============================================================
\echo ''
\echo '=== X1a: which content column(s) differ within duplicate groups ==='
WITH dup_groups AS (
    SELECT
        source_ref,
        count(DISTINCT member_id)       AS cnt_member_id,
        count(DISTINCT event_type)      AS cnt_event_type,
        count(DISTINCT event_ts)        AS cnt_event_ts,
        count(DISTINCT branch_id)       AS cnt_branch_id,
        count(DISTINCT device_id)       AS cnt_device_id,
        count(DISTINCT details::text)   AS cnt_details
    FROM events
    GROUP BY source_ref
    HAVING count(*) > 1
)
SELECT
    count(*)                                                               AS total_dup_groups,
    count(*) FILTER (WHERE cnt_member_id  > 1)                            AS member_id_differs,
    count(*) FILTER (WHERE cnt_event_type > 1)                            AS event_type_differs,
    count(*) FILTER (WHERE cnt_event_ts   > 1)                            AS event_ts_differs,
    count(*) FILTER (WHERE cnt_branch_id  > 1)                            AS branch_id_differs,
    count(*) FILTER (WHERE cnt_device_id  > 1)                            AS device_id_differs,
    count(*) FILTER (WHERE cnt_details    > 1)                            AS details_differ,
    count(*) FILTER (
        -- Use <= 1 for nullable columns (member_id, branch_id, device_id,
        -- details): count(DISTINCT NULL) = 0, not 1, so "= 1" misses groups
        -- where that column is NULL across all copies (e.g. details is NULL
        -- for all check_in / check_out events).
        WHERE cnt_member_id  <= 1 AND cnt_event_type = 1
          AND cnt_event_ts   =  1 AND cnt_branch_id <= 1
          AND cnt_device_id  <= 1 AND cnt_details   <= 1
    )                                                                      AS all_identical
FROM dup_groups;

-- ============================================================
-- CHECK: X1b – combination of differing columns per duplicate group
-- WHAT I'M TESTING: I am showing which specific combinations of columns
--   differ together, and how many groups fall into each combination.
--   This answers "is it always event_ts that changes, or sometimes
--   member_id, or both?"
-- WHY: If event_ts is the only changing column in most groups, "keep
--   most-recently-ingested" is safe only if the latest copy has the
--   correct timestamp.  If member_id also changes, the dedup rule must
--   be more conservative.
-- EXPECTED: One dominant combination (likely 'event_ts' alone or 'none').
-- SEVERITY IF IT FAILS: N/A (investigation)
-- ============================================================
\echo ''
\echo '=== X1b: combination of differing columns (ranked by group count) ==='
WITH dup_groups AS (
    SELECT
        source_ref,
        count(DISTINCT member_id)       AS cnt_member_id,
        count(DISTINCT event_type)      AS cnt_event_type,
        count(DISTINCT event_ts)        AS cnt_event_ts,
        count(DISTINCT branch_id)       AS cnt_branch_id,
        count(DISTINCT device_id)       AS cnt_device_id,
        count(DISTINCT details::text)   AS cnt_details
    FROM events
    GROUP BY source_ref
    HAVING count(*) > 1
)
SELECT
    COALESCE(NULLIF(trim(
        CASE WHEN cnt_member_id  > 1 THEN 'member_id '  ELSE '' END ||
        CASE WHEN cnt_event_type > 1 THEN 'event_type ' ELSE '' END ||
        CASE WHEN cnt_event_ts   > 1 THEN 'event_ts '   ELSE '' END ||
        CASE WHEN cnt_branch_id  > 1 THEN 'branch_id '  ELSE '' END ||
        CASE WHEN cnt_device_id  > 1 THEN 'device_id '  ELSE '' END ||
        CASE WHEN cnt_details    > 1 THEN 'details '    ELSE '' END
    ), ''), '(none – identical content)') AS differing_columns,
    count(*)                              AS groups
FROM dup_groups
GROUP BY 1
ORDER BY 2 DESC;

-- ============================================================
-- CHECK: X2 – five example duplicate groups (largest ingest-time gap)
-- WHAT I'M TESTING: I am showing every row for five duplicate groups
--   whose two copies arrived furthest apart in time.  Large gaps are
--   the hardest case for the dedup rule: the device held the event for
--   days before re-delivering it.
-- WHY: Concrete examples let me verify whether the later-ingested copy
--   consistently has the "better" value in the differing column, or
--   whether it varies and the rule needs to be more nuanced.
-- EXPECTED: The later copy should be the corrected version; if both
--   copies look valid, the dedup rule can safely take either.
-- SEVERITY IF IT FAILS: N/A (investigation)
-- ============================================================
\echo ''
\echo '=== X2: five duplicate groups with the largest gap between copies ==='
SELECT
    e.source_ref,
    e.event_id,
    e.member_id,
    e.event_type,
    e.event_ts,
    e.branch_id,
    e.device_id,
    e.ingested_at,
    e.details
FROM events e
JOIN (
    SELECT source_ref
    FROM events
    GROUP BY source_ref
    HAVING count(DISTINCT concat_ws('|',
               member_id::text, event_type, event_ts::text,
               branch_id::text, device_id, details::text)) > 1
    ORDER BY max(ingested_at) - min(ingested_at) DESC
    LIMIT 5
) examples USING (source_ref)
ORDER BY source_ref, ingested_at;

-- ============================================================
-- CHECK: X3a – D07-IN events by local month: total vs timestamps ahead
-- WHAT I'M TESTING: I am checking, for each local calendar month, how
--   many D07-IN events have event_ts ahead of ingested_at (the RC2
--   clock shift).  This confirms the exact start and end dates of the
--   affected window and whether the shift was sudden or gradual.
-- WHY: The visit report may need to correct or exclude D07-IN timestamps
--   only during the affected months.  Knowing the window precisely lets
--   me write the correction logic without hardcoding a date range.
-- EXPECTED: 0 % ahead outside Jun–Aug 2024; ~100 % ahead within the
--   affected window (Jun 6–Aug 6 2024 per 03_drilldown evidence).
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== X3a: D07-IN events by local month – total vs timestamps ahead ==='
SELECT
    to_char(event_ts AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM') AS local_month,
    count(*)                                                          AS total_events,
    count(*) FILTER (WHERE ingested_at < event_ts)                   AS ahead_count,
    round(
        100.0 * count(*) FILTER (WHERE ingested_at < event_ts)
        / NULLIF(count(*), 0), 1
    )                                                                 AS pct_ahead
FROM events
WHERE device_id = 'D07-IN'
GROUP BY 1
ORDER BY 1;

-- ============================================================
-- CHECK: X3b – SF check-out immediately followed by D07-IN check-in
--             within 3 h (inverted visit sequences from clock shift)
-- WHAT I'M TESTING: I am finding cases where, for a registered member
--   at branch 7 (Mission Bay), a D07-OUT check-out is followed by a
--   D07-IN check-in within 3 hours in timestamp order.  Because D07-IN
--   stamps events ~3 h ahead of the actual time, a real visit sequence
--   (check-in → check-out) appears inverted in the database
--   (check-out → check-in) for visits shorter than 3 h.
-- WHY: These inverted pairs are counted in S3a as 'recheckin_no_checkout'
--   or 'orphan check-outs', inflating the anomaly count specifically at
--   SF during Jun–Aug.  Isolating them lets me estimate how many SF
--   anomalies in S3 are caused by RC2 rather than real behaviour.
-- EXPECTED: Inverted pairs only in Jun–Aug 2024; zero in all other months.
--   (With the wrong dedup direction—DESC—we also saw 24 in March and 48
--   in October; those were re-delivered copies whose event_ts was set to
--   the batch re-delivery time, producing artificial out-of-order pairs.
--   They disappear when the correct first-delivery dedup is used.)
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== X3b: SF check-out followed by D07-IN check-in within 3 h, by month ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
),
sf_access AS (
    SELECT
        member_id,
        event_id,
        lower(event_type)               AS etype,
        event_ts,
        device_id,
        lead(lower(event_type)) OVER w  AS next_etype,
        lead(device_id)         OVER w  AS next_device,
        lead(event_ts)          OVER w  AS next_ts
    FROM deduped
    WHERE device_id IN ('D07-IN','D07-OUT')
      AND lower(event_type) IN ('check_in','check_out')
      AND member_id IN (SELECT member_id FROM members)
    WINDOW w AS (PARTITION BY member_id ORDER BY event_ts, event_id)
)
SELECT
    to_char(event_ts AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM') AS local_month,
    count(*) AS inverted_pairs
FROM sf_access
WHERE etype       = 'check_out'
  AND next_etype  = 'check_in'
  AND next_device = 'D07-IN'
  AND next_ts - event_ts <= interval '3 hours'
GROUP BY 1
ORDER BY 1;

-- ============================================================
-- CHECK: X4a – off-hours access events by local calendar month
-- WHAT I'M TESTING: I am counting deduped off-hours access events per
--   local calendar month using the correct first-delivery dedup (ASC).
--   The ~2 % "universal floor" seen in S9 was an artifact: with the
--   wrong latest-delivery dedup (DESC) the 3,036 re-delivered copies had
--   event_ts set to the batch re-delivery UTC time (~07:21), which is
--   00:21–03:21 local on every branch → off-hours.  Switching to ASC
--   replaces those with the original correct timestamps.
-- WHY: Confirming that the off-hours floor collapses to only Jun–Aug
--   under the correct dedup rule closes the open question from S9 and
--   proves the dedup direction.
-- EXPECTED: Only Jun–Aug 2024 have off-hours events (D07-IN clock shift,
--   RC2); all other months show 0.
-- SEVERITY IF IT FAILS: N/A (investigation)
-- ============================================================
\echo ''
\echo '=== X4a: off-hours access events by local calendar month ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
)
SELECT
    to_char(e.event_ts AT TIME ZONE b.timezone, 'YYYY-MM') AS local_month,
    count(*)                                                AS off_hours_events
FROM deduped e
JOIN branches b ON b.branch_id = e.branch_id
WHERE lower(e.event_type) IN ('check_in','check_out','friend_visit')
  AND (e.event_ts AT TIME ZONE b.timezone)::time
      NOT BETWEEN b.opens_at AND b.closes_at
GROUP BY 1
ORDER BY 1;

-- ============================================================
-- CHECK: X4b – off-hours access events by member type
-- WHAT I'M TESTING: I am splitting off-hours access events by whether
--   the member_id belongs to a registered member, an unknown id not
--   in the members table (test accounts, RC3), or is absent (NULL).
-- WHY: If test accounts (RC3) drive most off-hours events, the fix is
--   to filter them out.  If registered members dominate, the cause is
--   something else—a different clock issue, staff access, or a second
--   unknown bug.
-- EXPECTED: The bulk of off-hours events should come from registered
--   members, confirming that RC3 alone cannot explain the ~2 % floor.
-- SEVERITY IF IT FAILS: N/A (investigation)
-- ============================================================
\echo ''
\echo '=== X4b: off-hours access events by member type ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
)
SELECT
    CASE
        WHEN e.member_id IS NULL
             THEN 'no_member_id'
        WHEN e.member_id IN (SELECT member_id FROM members)
             THEN 'registered_member'
        ELSE 'unknown_id_not_in_members'
    END                     AS member_type,
    count(*)                AS off_hours_events
FROM deduped e
JOIN branches b ON b.branch_id = e.branch_id
WHERE lower(e.event_type) IN ('check_in','check_out','friend_visit')
  AND (e.event_ts AT TIME ZONE b.timezone)::time
      NOT BETWEEN b.opens_at AND b.closes_at
GROUP BY 1
ORDER BY 2 DESC;

-- ============================================================
-- CHECK: X4c – top 20 registered members by off-hours event count
-- WHAT I'M TESTING: I am listing the 20 registered members with the
--   most off-hours access events, with their branch spread, to see
--   whether a small group of members (staff, early-access pass holders)
--   accounts for a large share of the off-hours floor.
-- WHY: If 10–20 members produce most of the off-hours events, they are
--   likely staff or special-access members and should be excluded from
--   off-hours anomaly reports, not flagged as data errors.
-- EXPECTED: No single member accounts for a disproportionate share;
--   if a handful do, they deserve a note in DATA_QUALITY.md.
-- SEVERITY IF IT FAILS: N/A (investigation)
-- ============================================================
\echo ''
\echo '=== X4c: top 20 registered members by off-hours event count ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
)
SELECT
    e.member_id,
    count(*)                                                            AS off_hours_events,
    count(DISTINCT e.branch_id)                                         AS distinct_branches,
    string_agg(DISTINCT b.name, ', ' ORDER BY b.name)                  AS branches
FROM deduped e
JOIN branches b ON b.branch_id = e.branch_id
WHERE lower(e.event_type) IN ('check_in','check_out','friend_visit')
  AND e.member_id IN (SELECT member_id FROM members)
  AND (e.event_ts AT TIME ZONE b.timezone)::time
      NOT BETWEEN b.opens_at AND b.closes_at
GROUP BY e.member_id
ORDER BY off_hours_events DESC
LIMIT 20;

-- ============================================================
-- CHECK: X5 – test account events by branch and type, with off-hours
-- WHAT I'M TESTING: I am listing all deduped events produced by member
--   ids that are not in the members table (test accounts 990001 and
--   990002 from RC3), broken down by branch, event type, and whether
--   they fall outside opening hours.
-- WHY: Test accounts inflate the visit count and access metrics.  Their
--   branch and off-hours distribution shows whether they were used for
--   localised device testing (one branch) or system-wide integration
--   tests (all branches), which determines how to filter them in reports.
-- EXPECTED: Test events on all branches (integration tests), no CRM
--   events, a small off-hours share comparable to the branch baseline.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== X5: test account events by branch, type, and off-hours ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at ASC, event_id ASC
)
SELECT
    e.member_id,
    b.name                                                              AS branch_name,
    lower(e.event_type)                                                 AS event_type,
    count(*)                                                            AS total_events,
    count(*) FILTER (
        WHERE (e.event_ts AT TIME ZONE b.timezone)::time
              NOT BETWEEN b.opens_at AND b.closes_at
    )                                                                   AS off_hours_events
FROM deduped e
JOIN branches b ON b.branch_id = e.branch_id
WHERE e.member_id IS NOT NULL
  AND e.member_id NOT IN (SELECT member_id FROM members)
GROUP BY e.member_id, b.name, lower(e.event_type)
ORDER BY e.member_id, b.name, lower(e.event_type);
