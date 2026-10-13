import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: BR03 – every member marked active has a CRM history
// -- WHAT I'M TESTING: I am checking that every member whose
// --   snapshot status is 'active' (any casing) has at least one
// --   membership_started or membership_reactivated event.  Without
// --   a CRM history the active-in-a-month rule (BR) cannot be
// --   evaluated for that member.
// -- WHY: Members without CRM events produce NULL active-state at
// --   any point in time; active-members reports would either drop
// --   them silently or misclassify them.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'BR03',
  name: 'Every active member has at least one membership event',
  severity: 'warning',
  sql: `
    SELECT m.member_id, m.status, m.joined_on
    FROM members m
    WHERE lower(m.status) = 'active'
      AND NOT EXISTS (
        SELECT 1
        FROM events e
        WHERE e.member_id = m.member_id
          AND lower(e.event_type) IN (
            'membership_started',
            'membership_reactivated'
          )
      )
    ORDER BY member_id
  `,
};
