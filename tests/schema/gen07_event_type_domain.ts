import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: GEN07 – events.event_type is a known type
// -- WHAT I'M TESTING: I am checking that every event_type, compared
// --   case-insensitively, is one of the seven known types:
// --   membership_started / membership_reactivated / membership_cancelled
// --   / tier_changed / check_in / check_out / friend_visit.
// -- WHY: Every other check and the reports branch on event_type.  A
// --   new or renamed type (e.g. 'checkin', 'check-in', 'CANCEL') would
// --   silently fall through every filter and be dropped from counts
// --   with no error.  This is the domain guard for event_type, the
// --   analogue of GEN05/GEN06 for members.status / membership_tier.
// --   (Casing itself — the uppercase CHECK_IN from RC4 — is absorbed
// --   by lower() everywhere and documented as a finding, so it is not
// --   re-flagged here; this check targets UNKNOWN types.)
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'GEN07',
  name: 'Every event_type is one of the seven known types',
  severity: 'blocking',
  sql: `
    SELECT lower(event_type) AS unknown_type, count(*) AS rows
    FROM   events
    WHERE  lower(event_type) NOT IN (
             'membership_started', 'membership_reactivated',
             'membership_cancelled', 'tier_changed',
             'check_in', 'check_out', 'friend_visit'
           )
    GROUP  BY lower(event_type)
    ORDER  BY rows DESC
  `,
};
