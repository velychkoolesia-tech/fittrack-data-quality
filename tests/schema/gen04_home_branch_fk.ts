import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: GEN04 – members.home_branch_id references a real branch
// -- WHAT I'M TESTING: I am checking that every non-null
// --   home_branch_id in members points to a row in branches.
// --   S10d (exploration) found 5 dangling foreign keys.
// -- WHY: A missing home branch means we cannot look up the
// --   member's home timezone, city, or branch name.  Any report
// --   that joins members to branches on home_branch_id will
// --   silently drop those members.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'GEN04',
  name: "Every member's home branch references a real branch",
  severity: 'blocking',
  sql: `
    SELECT m.member_id, m.home_branch_id
    FROM   members m
    WHERE  m.home_branch_id IS NOT NULL
      AND  NOT EXISTS (
             SELECT 1 FROM branches b WHERE b.branch_id = m.home_branch_id
           )
    ORDER  BY m.member_id
  `,
};
