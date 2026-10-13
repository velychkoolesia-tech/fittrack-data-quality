import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: RC03 – CRM events are ingested within 7 days of event_ts
// -- WHAT I'M TESTING: I am checking that no CRM event arrives more
// --   than 7 days after its event_ts.  RC5 (exploration): all 420
// --   membership_cancelled events were ingested up to 32 days late
// --   due to a nightly batch job.
// -- WHY: Late cancellations mean the access-control system shows
// --   cancelled members as active for up to 32 days, allowing
// --   unauthorised access and inflating active-member counts.  A
// --   7-day threshold flags systematic batch delays without
// --   rejecting occasional minor lag.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'RC03',
  name: 'No CRM event is ingested more than 7 days after its event timestamp',
  severity: 'warning',
  sql: `
    SELECT
      lower(event_type)             AS event_type,
      count(*)                      AS late_events,
      max(ingested_at - event_ts)   AS max_lag,
      min(event_ts)                 AS earliest_late_event
    FROM   events
    WHERE  (device_id IS NULL OR device_id = '')
      AND  ingested_at - event_ts > interval '7 days'
    GROUP  BY 1
    ORDER  BY late_events DESC
  `,
};
