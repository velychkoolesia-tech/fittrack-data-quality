import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: BR02b – members.membership_tier matches event-derived tier
// -- WHAT I'M TESTING: I am comparing the members.membership_tier
// --   snapshot against the tier derived from each member's most
// --   recent tier-setting event (membership_started,
// --   membership_reactivated, or tier_changed).  S7 (exploration)
// --   found 8 mismatches.
// -- WHY: The friend-allowance calculation (BR07) uses the event-
// --   derived tier.  Any report that reads members.membership_tier
// --   directly would apply the wrong allowance cap for those 8
// --   members.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'BR02b',
  name: 'members.membership_tier snapshot agrees with event-derived tier',
  severity: 'warning',
  sql: `
    WITH latest_tier AS (
      SELECT DISTINCT ON (member_id)
        member_id,
        CASE lower(event_type)
          WHEN 'tier_changed'           THEN details->>'to'
          WHEN 'membership_started'     THEN details->>'tier'
          WHEN 'membership_reactivated' THEN details->>'tier'
        END AS derived_tier
      FROM   events
      WHERE  lower(event_type) IN (
               'tier_changed', 'membership_started', 'membership_reactivated'
             )
      ORDER  BY member_id, event_ts DESC, event_id DESC
    )
    SELECT
      m.member_id,
      m.membership_tier  AS snapshot_tier,
      lt.derived_tier
    FROM   members m
    JOIN   latest_tier lt USING (member_id)
    WHERE  lower(m.membership_tier) != lt.derived_tier
    ORDER  BY m.member_id
  `,
};
