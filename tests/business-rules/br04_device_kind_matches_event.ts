import type { Check } from '../src/lib/types';

// -- ============================================================
// -- CHECK: BR04 – device kind must match the event type it records
// -- WHAT I'M TESTING: I am verifying that check_in events come
// --   from entrance devices, check_out from exit devices, and
// --   friend_visit from front_desk devices.  The visit business rule
// --   defines a visit as check_in at a branch entrance + check_out
// --   at the same branch exit; mismatched devices break that pairing.
// -- WHY: A check_in recorded by an exit device, for example, would
// --   be impossible to match with a check_out, corrupting all visit
// --   counts.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'BR04',
  name: 'Device kind matches the event type it recorded',
  severity: 'blocking',
  sql: `
    SELECT e.event_id, e.event_type, e.device_id, d.kind
    FROM events e
    JOIN devices d ON d.device_id = e.device_id
    WHERE
      (lower(e.event_type) = 'check_in'      AND d.kind != 'entrance'  )
      OR (lower(e.event_type) = 'check_out'  AND d.kind != 'exit'      )
      OR (lower(e.event_type) = 'friend_visit' AND d.kind != 'front_desk')
    ORDER BY e.event_id
  `,
};
