import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: GEN03 – no two members share the same email address
// -- WHAT I'M TESTING: I am checking that each email appears on at
// --   most one member row.  S10b (exploration) found 5 duplicate
// --   email addresses shared by 10 members in this dataset.
// -- WHY: Duplicate emails typically indicate duplicate member
// --   records or shared accounts.  They make CRM targeting
// --   ambiguous and could cause the visit report to count one
// --   person's activity under two member IDs.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'GEN03',
  name: 'No two members share the same email address',
  severity: 'blocking',
  sql: `
    SELECT email, count(*) AS member_count, array_agg(member_id ORDER BY member_id) AS member_ids
    FROM   members
    WHERE  email IS NOT NULL AND email != ''
    GROUP  BY email
    HAVING count(*) > 1
    ORDER  BY count(*) DESC, email
  `,
};
