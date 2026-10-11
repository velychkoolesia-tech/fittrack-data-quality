import type { Check } from '../lib/types';

// -- ============================================================
// -- CHECK: GEN02 – member email addresses are well-formed
// -- WHAT I'M TESTING: I am checking that every member email
// --   matches a minimal valid pattern: non-whitespace characters
// --   before @, a domain, and at least one dot after @.
// -- WHY: Malformed emails block CRM outreach and indicate data-
// --   entry errors.  S10a (exploration) found 4 in this dataset.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'GEN02',
  name: 'All member email addresses are well-formed',
  severity: 'warning',
  kind: 'negative',
  sql: `
    SELECT member_id, email
    FROM   members
    WHERE  email IS NOT NULL
      AND  email != ''
      AND  email !~ '^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$'
    ORDER  BY member_id
  `,
};
