import type { Check } from '../src/lib/types';

// -- ============================================================
// -- CHECK: EC03 – registered members with check-outs but no check-ins
// -- WHAT I'M TESTING: I am checking for registered members who
// --   have at least one check_out event but zero check_in events
// --   in the entire dataset.  This is a hard edge case: a member
// --   who apparently left a gym they never entered.
// -- WHY: These members cannot have a valid visit under the business
// --   rule (visit = check_in + check_out).  Their check-outs are
// --   either orphan events from a lost check-in (e.g. sequence gap
// --   in a device) or a routing error that attributed the event to
// --   the wrong member.  If counted, they inflate check-out totals
// --   without a corresponding visit.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'EC03',
  name: 'No registered member has check-outs but zero check-ins',
  severity: 'warning',
  kind: 'edge-case',
  sql: `
    WITH deduped AS (
      SELECT DISTINCT ON (source_ref) *
      FROM events
      ORDER BY source_ref, ingested_at ASC, event_id ASC
    )
    SELECT DISTINCT e.member_id
    FROM deduped e
    WHERE lower(e.event_type) = 'check_out'
      AND e.member_id IN (SELECT member_id FROM members)
      AND NOT EXISTS (
        SELECT 1 FROM deduped ci
        WHERE ci.member_id = e.member_id
          AND lower(ci.event_type) = 'check_in'
      )
    ORDER BY e.member_id
  `,
};
