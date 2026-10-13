import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: BR07 – monthly friend visits do not exceed tier allowance
// -- WHAT I'M TESTING: I am checking that no member exceeds their
// --   tier's monthly friend-visit allowance in any calendar month
// --   (local time at the branch where the visit happened):
// --     basic → 2, standard → 3, premium → 8.
// --   The tier for a month is the member's latest tier-setting event
// --   (membership_started, membership_reactivated, tier_changed)
// --   before the end of that local calendar month.
// -- WHY: Allowance overruns indicate either a system control failure
// --   (front desk let extra friends in) or a data error in tier or
// --   friend_visit records, both of which affect the
// --   friend_allowance_monthly report.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'BR07',
  name: 'Monthly friend visits do not exceed tier allowance (basic 2 / standard 3 / premium 8)',
  severity: 'warning',
  sql: `
    WITH deduped AS (
      SELECT DISTINCT ON (source_ref) *
      FROM events
      ORDER BY source_ref, ingested_at ASC, event_id ASC
    ),
    -- Label each friend_visit with the local calendar month at its branch,
    -- and compute the UTC start of the following month for tier lookup.
    fv_labeled AS (
      SELECT
        e.member_id,
        to_char(e.event_ts AT TIME ZONE b.timezone, 'YYYY-MM')  AS local_month,
        -- First instant of the next local month, expressed as UTC timestamptz
        (date_trunc('month',
            (e.event_ts AT TIME ZONE b.timezone)::date::timestamp
          ) + interval '1 month'
        ) AT TIME ZONE b.timezone                                AS next_month_utc
      FROM deduped e
      JOIN branches b ON b.branch_id = e.branch_id
      WHERE lower(e.event_type) = 'friend_visit'
        AND e.member_id IN (SELECT member_id FROM members)
    ),
    -- Aggregate visits per member per local month; pick the earliest
    -- next_month_utc across branches (safe approximation: timezone offsets
    -- differ by at most a few hours, which is irrelevant for monthly tiers).
    fv_monthly AS (
      SELECT
        member_id,
        local_month,
        count(*)          AS friend_visits,
        min(next_month_utc) AS next_month_utc
      FROM fv_labeled
      GROUP BY member_id, local_month
    ),
    -- Resolve each member's tier at the end of the local month.
    -- Fall back to members.membership_tier if no tier event exists yet.
    member_tier AS (
      SELECT DISTINCT ON (fv.member_id, fv.local_month)
        fv.member_id,
        fv.local_month,
        fv.friend_visits,
        COALESCE(
          CASE lower(te.event_type)
            WHEN 'tier_changed'           THEN te.details->>'to'
            WHEN 'membership_started'     THEN te.details->>'tier'
            WHEN 'membership_reactivated' THEN te.details->>'tier'
          END,
          m.membership_tier
        ) AS tier
      FROM fv_monthly fv
      JOIN members m ON m.member_id = fv.member_id
      LEFT JOIN events te ON te.member_id = fv.member_id
        AND lower(te.event_type) IN (
          'tier_changed', 'membership_started', 'membership_reactivated'
        )
        AND te.event_ts < fv.next_month_utc
      ORDER BY fv.member_id, fv.local_month, te.event_ts DESC, te.event_id DESC
    )
    SELECT
      member_id,
      local_month,
      tier,
      friend_visits,
      CASE tier
        WHEN 'basic'    THEN 2
        WHEN 'standard' THEN 3
        WHEN 'premium'  THEN 8
        ELSE 0
      END AS allowance
    FROM member_tier
    WHERE friend_visits > CASE tier
      WHEN 'basic'    THEN 2
      WHEN 'standard' THEN 3
      WHEN 'premium'  THEN 8
      ELSE 0
    END
    ORDER BY member_id, local_month
  `,
};
