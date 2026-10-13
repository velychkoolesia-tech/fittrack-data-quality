import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: BR01 – no invalid CRM state-machine transitions
// -- WHAT I'M TESTING: I am verifying that consecutive membership
// --   events per member follow only valid transitions:
// --   (first) → started | reactivated
// --   started | reactivated → cancelled
// --   cancelled → reactivated
// -- WHY: Any other sequence means the membership state is
// --   ambiguous at some point in time, corrupting every report
// --   that derives active/cancelled status from events.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'BR01',
  name: 'No invalid CRM membership state-machine transitions',
  severity: 'blocking',
  sql: `
    WITH ordered AS (
      SELECT
        member_id,
        lower(event_type)   AS etype,
        event_ts,
        -- COALESCE the "no previous event" case to a sentinel: a bare
        -- NULL makes prev_etype IN (...) evaluate to NULL (not FALSE)
        -- below, which would let a first-event cancellation slip through.
        COALESCE(
          lag(lower(event_type)) OVER (
            PARTITION BY member_id ORDER BY event_ts, event_id
          ), 'none')         AS prev_etype
      FROM events
      WHERE lower(event_type) IN (
        'membership_started',
        'membership_reactivated',
        'membership_cancelled'
      )
    )
    SELECT member_id, prev_etype AS from_state, etype AS to_state, event_ts
    FROM ordered
    WHERE NOT (
      -- first event (no previous): only started or reactivated.
      -- A first-event membership_cancelled fails here and is flagged.
      (prev_etype = 'none'
        AND etype IN ('membership_started', 'membership_reactivated'))
      -- active → cancelled
      OR (prev_etype IN ('membership_started', 'membership_reactivated')
        AND etype = 'membership_cancelled')
      -- cancelled → reactivated
      OR (prev_etype = 'membership_cancelled'
        AND etype = 'membership_reactivated')
    )
    ORDER BY member_id, event_ts
  `,
};
