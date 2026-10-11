import type { Check } from '../lib/types';

// -- ============================================================
// -- CHECK: BR05 – event branch_id matches the device's branch_id
// -- WHAT I'M TESTING: I am checking that every device event is
// --   credited to the same branch the recording device belongs to.
// --   A mismatch means the event was routed to the wrong branch,
// --   applying the wrong timezone and breaking visit pairing.
// -- WHY: The visit business rule requires check_in and check_out at
// --   the same branch; a branch mismatch makes valid pairs appear
// --   cross-branch and valid single events appear as anomalies.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'BR05',
  name: 'Event branch_id matches the recording device branch_id',
  severity: 'blocking',
  sql: `
    SELECT
      e.event_id,
      e.device_id,
      e.branch_id   AS event_branch,
      d.branch_id   AS device_branch
    FROM events e
    JOIN devices d ON d.device_id = e.device_id
    WHERE e.branch_id != d.branch_id
    ORDER BY e.event_id
  `,
};
