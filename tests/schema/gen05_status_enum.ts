import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: GEN05 – members.status contains only valid values
// -- WHAT I'M TESTING: I am checking that every row in members has
// --   a status of exactly 'active' or 'cancelled' (lowercase).
// --   S10e (exploration) found 5 rows with 'Active' (capital A).
// -- WHY: Case-sensitive comparisons on status silently exclude
// --   mis-cased rows.  'Active' != 'active', so WHERE status =
// --   'active' misses those 5 members, under-counting the active
// --   population in every report that reads the snapshot.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'GEN05',
  name: "Every member status is exactly 'active' or 'cancelled'",
  severity: 'blocking',
  sql: `
    SELECT member_id, status
    FROM   members
    WHERE  status NOT IN ('active', 'cancelled')
    ORDER  BY member_id
  `,
};
