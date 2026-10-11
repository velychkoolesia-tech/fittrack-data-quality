-- ============================================================
-- FILE: 04_integrity.sql
-- GOAL: I am auditing source_ref sequence integrity, visit pairing,
--       membership state consistency at the moment of access, the CRM
--       state machine, tier history, the members snapshot, friend-visit
--       rule compliance, off-hours patterns, and member profile quality.
--       Every query that touches device events deduplicates by source_ref
--       first (keeping the most-recently-ingested copy per source_ref;
--       the final dedup rule will be locked in planning step 1).
-- CONTEXT: From 01–03: 3,756 duplicate device rows, all 24 devices
--          affected (RC1); D07-IN timestamps 3 h ahead Jun–Aug 2024 (RC2);
--          test accounts 990001/990002 (RC3); uppercase CHECK_IN from
--          D04-IN (RC4); 420 CRM cancellations ingested up to 32 days
--          late (RC5); members 1031 and 1132 have no CRM history (RC6);
--          5 rows with status = 'Active' (RC7); ~2 % of access events
--          fall in local hours 00–03 (open question).
-- ============================================================

-- ============================================================
-- CHECK: S1a – source_ref pattern inventory
-- WHAT I'M TESTING: I am checking that every source_ref matches either
--   the device format '<device_id>:<digits>' or the CRM format 'crm:<n>'.
--   Any row that matches neither pattern is structurally malformed.
-- WHY: Malformed refs break the dedup rule and prevent sequence-gap
--   analysis; the visit report depends on clean dedup.
-- EXPECTED: All rows fall into the two known patterns; 0 malformed.
-- SEVERITY IF IT FAILS: blocking
-- ============================================================
\echo ''
\echo '=== S1a: source_ref pattern inventory ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
)
SELECT
    CASE
        WHEN source_ref ~ '^crm:[0-9]+$'
             THEN 'crm:<n>'
        WHEN device_id IS NOT NULL AND device_id != ''
             AND source_ref LIKE (device_id || ':%')
             AND split_part(source_ref, ':', 2) ~ '^[0-9]+$'
             THEN 'device:<seq>'
        ELSE 'malformed/unexpected'
    END AS ref_pattern,
    count(*)                    AS n,
    count(DISTINCT source_ref)  AS distinct_refs
FROM deduped
GROUP BY 1
ORDER BY 2 DESC;

-- ============================================================
-- CHECK: S1b – source_ref prefix vs device_id mismatch
-- WHAT I'M TESTING: I am checking that the part of source_ref before the
--   colon is identical to the device_id column on the same row.  A
--   mismatch would mean the event was stamped by one device but credited
--   to another.
-- WHY: Wrong attribution scatters a device's sequence numbers across
--   multiple devices, making gap detection unreliable.
-- EXPECTED: 0 rows.
-- SEVERITY IF IT FAILS: blocking
-- ============================================================
\echo ''
\echo '=== S1b: source_ref prefix vs device_id mismatch ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
)
SELECT
    device_id,
    split_part(source_ref, ':', 1) AS ref_prefix,
    count(*)                       AS n
FROM deduped
WHERE device_id IS NOT NULL AND device_id != ''
  AND split_part(source_ref, ':', 1) != device_id
GROUP BY 1, 2
ORDER BY 3 DESC;

-- ============================================================
-- CHECK: S1c – sequence gaps per device
-- WHAT I'M TESTING: I am checking whether, for each device, every
--   integer between the observed minimum and maximum sequence number is
--   present after dedup.  Missing integers represent events that were
--   sent but never arrived.
-- WHY: Gaps mean lost check-in or check-out events, which inflate the
--   "never closed" visit count in S3 and undercount the visits report.
-- EXPECTED: gap_count = 0 for every device.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S1c: sequence gaps per device ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
),
seqs AS (
    SELECT
        device_id,
        split_part(source_ref, ':', 2)::bigint AS seq
    FROM deduped
    WHERE device_id IS NOT NULL AND device_id != ''
      AND source_ref  LIKE (device_id || ':%')
      AND split_part(source_ref, ':', 2) ~ '^[0-9]+$'
)
SELECT
    device_id,
    min(seq)                              AS min_seq,
    max(seq)                              AS max_seq,
    count(*)                              AS received,
    (max(seq) - min(seq) + 1)             AS expected,
    (max(seq) - min(seq) + 1) - count(*)  AS gap_count
FROM seqs
GROUP BY device_id
ORDER BY gap_count DESC;

-- ============================================================
-- CHECK: S2 – double scans (rapid consecutive check-ins)
-- WHAT I'M TESTING: I am checking whether the same real member has two
--   distinct check-in events (different source_refs, so not an RC1
--   duplicate) within 1, 5, or 30 minutes.
-- WHY: A genuine double-scan counts one person twice in the visit report;
--   within 1 min it is almost certainly an accidental hardware re-trigger.
-- EXPECTED: 0 within 1 minute; a small number within 5 and 30 min is
--   plausible (e.g. a member who left and immediately returned).
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S2: double scans (rapid consecutive check-ins) ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
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
-- CHECK: S3a – check-in outcomes (what follows each check-in)
-- WHAT I'M TESTING: I am classifying every deduped check-in by real
--   members by what the next access event for that member is: a paired
--   check-out at the same branch (clean), a check-out at a different
--   branch, another check-in without a prior check-out, or no subsequent
--   event at all.  Long visits (> 6 h) are flagged separately.
-- WHY: The visit report counts a visit as a check-in/check-out pair.
--   The share of unpaired or cross-branch check-ins determines how large
--   the counting decisions in step 1 of the plan will be.
-- EXPECTED: Most check-ins are clean pairs; a small "no subsequent event"
--   tail is expected for late-December activity at year-end.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S3a: check-in outcomes ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
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
-- CHECK: S3b – orphan and stacked check-outs
-- WHAT I'M TESTING: I am checking whether any check-out is preceded by
--   another check-out (or is the very first event for that member),
--   meaning there was no open visit to close.  A "paired_diff_branch"
--   check-out closes a check-in from a different branch—still suspicious.
-- WHY: An orphan check-out means either a lost check-in (sequence gap)
--   or a routing error.  It should not count as completing a visit.
-- EXPECTED: 0 orphans (first-ever check-outs) and 0 stacked check-outs.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S3b: orphan and stacked check-outs ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
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
-- CHECK: S4 – membership state at the moment of each check-in
-- WHAT I'M TESTING: I am checking, for each deduped check-in by a
--   registered member, what their CRM membership state was at that exact
--   moment (active via membership_started or membership_reactivated,
--   cancelled, or no prior CRM event at all).
-- WHY: Cancelled members checking in is a business-rule violation.  The
--   visit report needs a policy decision on whether to count those visits.
--   "No prior CRM event" covers members 1031 and 1132 (RC6).
-- EXPECTED: All check-ins happen while the member is active.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S4: membership state at moment of each check-in ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
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
-- CHECK: S5 – CRM state machine transition matrix
-- WHAT I'M TESTING: I am building a transition matrix of consecutive
--   CRM state events (membership_started, membership_reactivated,
--   membership_cancelled) per member, to identify invalid or duplicated
--   transitions (e.g. cancelled → cancelled).
-- WHY: Invalid transitions mis-classify a member's state at any point in
--   time; the active-members report and the membership_state check in S4
--   both depend on a correct CRM event sequence.
-- EXPECTED: Only valid transitions: (first event) → started; started →
--   cancelled; reactivated → cancelled; cancelled → reactivated.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S5: CRM state machine transition matrix ==='
WITH crm_states AS (
    SELECT
        member_id,
        lower(event_type) AS etype,
        event_ts,
        lag(lower(event_type)) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS prev_etype
    FROM events
    WHERE lower(event_type) IN ('membership_started','membership_reactivated','membership_cancelled')
)
SELECT
    COALESCE(prev_etype, '(first event)') AS from_state,
    etype                                  AS to_state,
    count(*)                               AS n
FROM crm_states
GROUP BY 1, 2
ORDER BY 1, 2;

-- ============================================================
-- CHECK: S6 – tier history validation
-- WHAT I'M TESTING: I am checking (a) whether each tier_changed event's
--   'from' field matches the tier that was in effect at that moment
--   (the 'to' of the previous tier-setting event); (b) whether any
--   tier_changed is a no-op (from = to); (c) whether any tier value
--   outside {basic, standard, premium} appears.
-- WHY: A wrong 'from' field suggests the CRM sent a stale snapshot.
--   Invalid tier values break friend-allowance calculations.  No-ops
--   are harmless but inflate the event count.
-- EXPECTED: 0 mismatches, 0 no-ops, all values in {basic, standard, premium}.
-- SEVERITY IF IT FAILS: blocking for invalid values; warning otherwise
-- ============================================================
\echo ''
\echo '=== S6: tier history validation ==='
WITH tier_events AS (
    SELECT
        member_id,
        event_ts,
        event_id,
        lower(event_type) AS etype,
        CASE lower(event_type)
            WHEN 'tier_changed'           THEN details->>'from'
            ELSE NULL
        END AS tier_from,
        CASE lower(event_type)
            WHEN 'tier_changed'           THEN details->>'to'
            WHEN 'membership_started'     THEN details->>'tier'
            WHEN 'membership_reactivated' THEN details->>'tier'
        END AS tier_to
    FROM events
    WHERE lower(event_type) IN ('tier_changed','membership_started','membership_reactivated')
),
with_expected AS (
    SELECT
        *,
        lag(tier_to) OVER (PARTITION BY member_id ORDER BY event_ts, event_id) AS expected_from
    FROM tier_events
)
SELECT
    count(*) FILTER (
        WHERE etype = 'tier_changed'
          AND expected_from IS NOT NULL
          AND tier_from != expected_from
    )                                                     AS from_mismatch,
    count(*) FILTER (
        WHERE etype = 'tier_changed' AND tier_from = tier_to
    )                                                     AS noop_tier_changes,
    count(*) FILTER (
        WHERE etype = 'tier_changed' AND expected_from IS NULL
    )                                                     AS changed_without_prior_tier,
    count(*) FILTER (
        WHERE etype = 'tier_changed'
          AND tier_from NOT IN ('basic','standard','premium')
    )                                                     AS invalid_from_value,
    count(*) FILTER (
        WHERE tier_to IS NOT NULL
          AND tier_to NOT IN ('basic','standard','premium')
    )                                                     AS invalid_to_value,
    count(*) FILTER (WHERE etype = 'tier_changed')        AS total_tier_changes
FROM with_expected;

-- ============================================================
-- CHECK: S7 – CRM snapshot (members table) vs event-derived state
-- WHAT I'M TESTING: I am comparing members.status and
--   members.membership_tier against what I can derive from the most
--   recent CRM events for each member.  A mismatch means the snapshot
--   row is stale or was never updated.
-- WHY: Any report or application that reads members.status directly
--   instead of rebuilding state from events will silently count the
--   wrong population.  RC7 already showed 5 casing variants; this
--   measures the full mismatch including stale values.
-- EXPECTED: 0 status mismatches, 0 tier mismatches (after case
--   normalisation).
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S7: CRM snapshot vs event-derived state ==='
WITH latest_state AS (
    SELECT DISTINCT ON (member_id)
        member_id,
        lower(event_type) AS last_etype
    FROM events
    WHERE lower(event_type) IN ('membership_started','membership_reactivated','membership_cancelled')
    ORDER BY member_id, event_ts DESC, event_id DESC
),
latest_tier AS (
    SELECT DISTINCT ON (member_id)
        member_id,
        CASE lower(event_type)
            WHEN 'tier_changed'           THEN details->>'to'
            WHEN 'membership_started'     THEN details->>'tier'
            WHEN 'membership_reactivated' THEN details->>'tier'
        END AS derived_tier
    FROM events
    WHERE lower(event_type) IN ('tier_changed','membership_started','membership_reactivated')
    ORDER BY member_id, event_ts DESC, event_id DESC
)
SELECT
    count(*) FILTER (
        WHERE ls.last_etype IS NOT NULL
          AND lower(m.status) != CASE ls.last_etype
                WHEN 'membership_cancelled' THEN 'cancelled'
                ELSE 'active'
              END
    )                                   AS status_snapshot_mismatch,
    count(*) FILTER (
        WHERE lt.derived_tier IS NOT NULL
          AND lower(m.membership_tier) != lt.derived_tier
    )                                   AS tier_snapshot_mismatch,
    count(*) FILTER (WHERE ls.last_etype  IS NULL) AS no_crm_state_events,
    count(*) FILTER (WHERE lt.derived_tier IS NULL) AS no_tier_events,
    count(*)                             AS total_members
FROM members m
LEFT JOIN latest_state ls USING (member_id)
LEFT JOIN latest_tier  lt USING (member_id);

-- ============================================================
-- CHECK: S8 – friend visits outside any open member visit
-- WHAT I'M TESTING: I am checking whether each deduped friend_visit
--   occurs while the member has an open visit at that branch (i.e. their
--   most recent access event at that branch before the friend_visit is a
--   check_in, not a check_out and not absent).
-- WHY: Business rule: a friend can only enter together with the member
--   (ASSIGNMENT §4).  A friend_visit with no open visit is either a
--   data error or an undocumented override.
-- EXPECTED: 0 friend_visits outside an open visit.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S8: friend visits outside any open member visit ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
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
    count(*)                                                                    AS total_friend_visits,
    count(*) FILTER (WHERE last_ev.etype IS NULL
                     OR   last_ev.etype = 'check_out')                         AS outside_open_visit
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
-- CHECK: S9 – off-hours event share per device
-- WHAT I'M TESTING: I am measuring, for each device, the share of
--   deduped access events that fall outside 05:00–23:00 local time.
--   D07-IN's timestamps are 3 h ahead (RC2), so its off-hours share is
--   expected to be inflated and should not be read as real member
--   activity.
-- WHY: A high off-hours share on a single device is a signal of a clock
--   or timezone bug (as RC2 already showed); elevated off-hours across
--   all devices would indicate a different, still-unknown cause.
-- EXPECTED: Near-zero off-hours (< 1 %) for all devices except D07-IN.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S9: off-hours event share per device ==='
WITH deduped AS (
    SELECT DISTINCT ON (source_ref) *
    FROM events
    ORDER BY source_ref, ingested_at DESC, event_id DESC
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

-- ============================================================
-- CHECK: S10a – email format
-- WHAT I'M TESTING: I am checking that every member email is non-null,
--   non-empty, and matches a minimal valid email pattern (something @
--   something . something).
-- WHY: Malformed emails block CRM outreach and indicate data-entry errors
--   in the member profile.
-- EXPECTED: 0 null or malformed emails.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S10a: email format ==='
SELECT
    count(*) FILTER (WHERE email IS NULL OR email = '')                   AS null_or_empty,
    count(*) FILTER (
        WHERE email IS NOT NULL AND email != ''
          AND email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    )                                                                     AS invalid_format,
    count(*)                                                              AS total_members
FROM members;

-- ============================================================
-- CHECK: S10b – duplicate email addresses
-- WHAT I'M TESTING: I am checking whether any email address appears on
--   more than one member row.
-- WHY: Duplicate emails typically mean duplicate member records or shared
--   accounts; the visit report could count one person twice.
-- EXPECTED: 0 members sharing an email.
-- SEVERITY IF IT FAILS: blocking
-- ============================================================
\echo ''
\echo '=== S10b: duplicate email addresses ==='
SELECT
    count(*)                AS members_sharing_an_email,
    count(DISTINCT email)   AS distinct_emails_with_dups
FROM members
WHERE email IS NOT NULL AND email != ''
  AND email IN (
      SELECT email FROM members
      WHERE email IS NOT NULL AND email != ''
      GROUP BY email HAVING count(*) > 1
  );

-- ============================================================
-- CHECK: S10c – date-of-birth plausibility
-- WHAT I'M TESTING: I am checking that every member DOB corresponds to
--   an age between 16 and 100 in calendar year 2024 (born between
--   1924-01-01 and 2008-12-31).
-- WHY: Implausible DOBs (far in the past or future) indicate data-entry
--   errors; an underage member may violate gym terms of service.
-- EXPECTED: 0 null or out-of-range DOBs.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S10c: date-of-birth plausibility ==='
SELECT
    count(*) FILTER (WHERE date_of_birth IS NULL)                        AS null_dob,
    count(*) FILTER (WHERE date_of_birth IS NOT NULL
                     AND   date_of_birth > '2008-12-31')                 AS too_young_in_2024,
    count(*) FILTER (WHERE date_of_birth IS NOT NULL
                     AND   date_of_birth < '1924-01-01')                 AS too_old_in_2024,
    min(date_of_birth)                                                   AS oldest_dob,
    max(date_of_birth)                                                   AS youngest_dob,
    count(*)                                                             AS total_members
FROM members;

-- ============================================================
-- CHECK: S10d – home_branch_id referential integrity
-- WHAT I'M TESTING: I am checking that every non-null home_branch_id
--   in members points to an existing row in branches.
-- WHY: A dangling home_branch_id means we cannot look up the branch name,
--   timezone, or opening hours for that member.
-- EXPECTED: 0 invalid home_branch_id values.
-- SEVERITY IF IT FAILS: blocking
-- ============================================================
\echo ''
\echo '=== S10d: home_branch_id referential integrity ==='
SELECT count(*) AS invalid_home_branch_count
FROM members
WHERE home_branch_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM branches WHERE branch_id = members.home_branch_id
  );

-- ============================================================
-- CHECK: S10e – members.status value inventory
-- WHAT I'M TESTING: I am listing every distinct value of members.status
--   to catch unexpected casing or unknown values.  RC7 already found 5
--   rows with 'Active' (capital A); this confirms the full picture.
-- WHY: Code that does WHERE status = 'active' silently misses 'Active'
--   rows; the active-members report is directly affected.
-- EXPECTED: Only 'active' and 'cancelled' in exact lowercase.
-- SEVERITY IF IT FAILS: blocking
-- ============================================================
\echo ''
\echo '=== S10e: members.status value inventory ==='
SELECT
    status,
    count(*) AS n
FROM members
GROUP BY 1
ORDER BY 2 DESC;

-- ============================================================
-- CHECK: S10f – members.membership_tier value inventory
-- WHAT I'M TESTING: I am listing every distinct value of
--   members.membership_tier to catch unexpected values.
-- WHY: Unknown tier values break friend-allowance calculations; a tier
--   outside {basic, standard, premium} has no defined allowance.
-- EXPECTED: Only 'basic', 'standard', 'premium' in exact lowercase.
-- SEVERITY IF IT FAILS: blocking
-- ============================================================
\echo ''
\echo '=== S10f: members.membership_tier value inventory ==='
SELECT
    membership_tier,
    count(*) AS n
FROM members
GROUP BY 1
ORDER BY 2 DESC;

-- ============================================================
-- CHECK: S11 – members.joined_on vs first membership_started event
-- WHAT I'M TESTING: I am checking that members.joined_on matches the
--   UTC calendar date of the member's first membership_started event.
--   A mismatch suggests the profile was back-dated, or the event
--   timestamp was corrected without updating the profile field.
-- WHY: Queries that use joined_on as a proxy for membership start will
--   be wrong for any member where the two dates diverge.
-- EXPECTED: 0 mismatches.
-- SEVERITY IF IT FAILS: warning
-- ============================================================
\echo ''
\echo '=== S11: joined_on vs first membership_started ==='
WITH first_started AS (
    SELECT DISTINCT ON (member_id)
        member_id,
        (event_ts AT TIME ZONE 'UTC')::date AS first_started_utc_date
    FROM events
    WHERE lower(event_type) = 'membership_started'
    ORDER BY member_id, event_ts
)
SELECT
    count(*)                                                                   AS total_members,
    count(*) FILTER (WHERE fs.member_id IS NULL)                               AS no_membership_started,
    count(*) FILTER (
        WHERE fs.member_id IS NOT NULL
          AND m.joined_on != fs.first_started_utc_date
    )                                                                          AS joined_on_mismatch,
    min(m.joined_on - fs.first_started_utc_date) FILTER (
        WHERE fs.member_id IS NOT NULL
          AND m.joined_on != fs.first_started_utc_date
    )                                                                          AS min_gap_days,
    max(m.joined_on - fs.first_started_utc_date) FILTER (
        WHERE fs.member_id IS NOT NULL
          AND m.joined_on != fs.first_started_utc_date
    )                                                                          AS max_gap_days
FROM members m
LEFT JOIN first_started fs USING (member_id);
