import type { Check } from '../src/lib/types';

// -- ============================================================
// -- CHECK: POS02 – every branch has at least one check-in event
// -- WHAT I'M TESTING: I am verifying that each branch in the
// --   branches table has at least one registered member check-in.
// --   A branch with no check-ins may mean the access-control
// --   pipeline for that location is broken or data was not loaded.
// -- WHY: A branch absent from the events feed produces a silent
// --   zero in the visits-per-branch report, which management would
// --   read as a closed branch rather than a data gap.
// -- EXPECTED: 0 rows (every branch has ≥ 1 check-in).
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'POS02',
  name: 'Every branch has at least one registered-member check-in',
  severity: 'warning',
  kind: 'positive',
  sql: `
    SELECT b.branch_id, b.name, b.city
    FROM branches b
    WHERE NOT EXISTS (
      SELECT 1
      FROM events e
      WHERE e.branch_id = b.branch_id
        AND lower(e.event_type) = 'check_in'
        AND e.member_id IN (SELECT member_id FROM members)
    )
    ORDER BY b.branch_id
  `,
};
