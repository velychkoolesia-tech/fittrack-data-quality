import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: GEN01 – critical fields must never be null
// -- WHAT I'M TESTING: I am checking that the fields every other
// --   check relies on are populated: events.branch_id and
// --   events.member_id (needed for timezone lookup and member
// --   filtering), and members profile fields needed for CRM logic
// --   and outreach (email, status, tier, joined_on).
// -- WHY: A null branch_id breaks timezone conversion and visit
// --   counting.  A null status breaks active-member reports.  These
// --   are the structural pre-conditions every other check assumes.
// -- EXPECTED: 0 rows (no nulls in any critical field).
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'GEN01',
  name: 'Critical fields are not null',
  severity: 'blocking',
  kind: 'negative',
  sql: `
    SELECT field, null_count
    FROM (
      SELECT 'events.branch_id'       AS field, count(*) AS null_count
      FROM   events WHERE branch_id IS NULL
      UNION ALL
      SELECT 'events.member_id',       count(*)
      FROM   events WHERE member_id IS NULL
      UNION ALL
      SELECT 'members.email',          count(*)
      FROM   members WHERE email IS NULL OR email = ''
      UNION ALL
      SELECT 'members.status',         count(*)
      FROM   members WHERE status IS NULL
      UNION ALL
      SELECT 'members.membership_tier',count(*)
      FROM   members WHERE membership_tier IS NULL
      UNION ALL
      SELECT 'members.joined_on',      count(*)
      FROM   members WHERE joined_on IS NULL
    ) counts
    WHERE null_count > 0
    ORDER BY null_count DESC
  `,
};
