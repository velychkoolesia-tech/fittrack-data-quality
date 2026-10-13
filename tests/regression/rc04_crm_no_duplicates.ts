import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: RC04 – CRM source_refs are unique (no CRM duplicates)
// -- WHAT I'M TESTING: I am checking that no CRM source_ref
// --   (matching '^crm:[0-9]+$') appears more than once.  RC1
// --   (exploration) confirmed that all 3,736 duplicate groups come
// --   from device events; zero CRM duplicates exist.  This check
// --   is a regression guard: CRM duplicates would mean a membership
// --   event was applied twice, corrupting the state machine.
// -- WHY: A duplicated membership_started or membership_cancelled
// --   event creates an invalid state-machine transition (BR01 would
// --   catch the consequence, but this catches the root cause).
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'RC04',
  name: 'CRM source_refs are unique (no CRM event delivered twice)',
  severity: 'warning',
  sql: `
    SELECT source_ref, count(*) AS occurrences
    FROM   events
    WHERE  source_ref ~ '^crm:[0-9]+$'
    GROUP  BY source_ref
    HAVING count(*) > 1
    ORDER  BY occurrences DESC, source_ref
  `,
};
