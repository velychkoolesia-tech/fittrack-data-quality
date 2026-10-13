import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: BR02 – members.status matches event-derived state
// -- WHAT I'M TESTING: I am comparing the members.status snapshot
// --   against the state derived from each member's latest CRM event.
// --   The business rule states membership state comes from events;
// --   the snapshot is a convenience field that must agree.
// -- WHY: Any query or application that reads members.status directly
// --   instead of deriving state from events will silently count the
// --   wrong population.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'BR02',
  name: "Every member's status matches the state derived from events",
  severity: 'warning',
  sql: `
    WITH latest_state AS (
      SELECT DISTINCT ON (member_id)
        member_id,
        lower(event_type) AS last_event
      FROM events
      WHERE lower(event_type) IN (
        'membership_started',
        'membership_reactivated',
        'membership_cancelled'
      )
      ORDER BY member_id, event_ts DESC, event_id DESC
    )
    SELECT
      m.member_id,
      m.status                    AS snapshot_status,
      CASE ls.last_event
        WHEN 'membership_cancelled' THEN 'cancelled'
        ELSE 'active'
      END                         AS derived_status
    FROM members m
    JOIN latest_state ls USING (member_id)
    WHERE lower(m.status) != CASE ls.last_event
      WHEN 'membership_cancelled' THEN 'cancelled'
      ELSE 'active'
    END
    ORDER BY member_id
  `,
};
