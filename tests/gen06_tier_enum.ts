import type { Check } from '../src/lib/types';

// -- ============================================================
// -- CHECK: GEN06 – members.membership_tier contains only valid values
// -- WHAT I'M TESTING: I am checking that every membership_tier is
// --   exactly 'basic', 'standard', or 'premium' (lowercase).
// -- WHY: The friend-allowance calculation (BR07) maps tier names
// --   to numeric limits.  An unknown tier value maps to 0 (CASE
// --   ELSE 0), silently treating the member as having no allowance
// --   instead of raising an error.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'GEN06',
  name: "members.membership_tier is exactly 'basic', 'standard', or 'premium'",
  severity: 'blocking',
  kind: 'negative',
  sql: `
    SELECT member_id, membership_tier
    FROM   members
    WHERE  membership_tier NOT IN ('basic', 'standard', 'premium')
    ORDER  BY member_id
  `,
};
