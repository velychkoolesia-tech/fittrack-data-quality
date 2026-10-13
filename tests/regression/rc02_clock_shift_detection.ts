import type { Check } from '../../src/lib/types';
import { DEDUPED_FIRST_DELIVERY } from '../../src/lib/sql';

// -- ============================================================
// -- CHECK: RC02 – no device sends events ahead of ingestion time
// -- WHAT I'M TESTING: I am checking that no device has events
// --   where event_ts is more than 5 minutes ahead of ingested_at.
// --   RC2 (exploration): D07-IN had 1,542 events with event_ts
// --   ~3 h ahead of ingest during Jun–Aug 2024 because its clock
// --   was set to the wrong timezone.
// -- WHY: A clock-shifted device produces wrong local timestamps,
// --   breaks visit pairing (inverted check_in/check_out order),
// --   and creates phantom off-hours events.  The 5-minute
// --   threshold absorbs legitimate clock skew without masking a
// --   timezone misconfiguration.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'RC02',
  name: 'No event is timestamped more than 5 minutes ahead of ingestion',
  severity: 'blocking',
  sql: `
    WITH deduped AS (${DEDUPED_FIRST_DELIVERY})
    SELECT
      device_id,
      count(*)                              AS events_ahead,
      min(event_ts - ingested_at)           AS min_ahead,
      max(event_ts - ingested_at)           AS max_ahead,
      min(event_ts)                         AS first_affected,
      max(event_ts)                         AS last_affected
    FROM   deduped
    WHERE  device_id IS NOT NULL AND device_id != ''
      AND  event_ts > ingested_at + interval '5 minutes'
    GROUP  BY device_id
    ORDER  BY events_ahead DESC
  `,
};
