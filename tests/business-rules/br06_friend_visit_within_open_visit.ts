import type { Check } from '../../src/lib/types';
import { DEDUPED_FIRST_DELIVERY, REGISTERED_MEMBER } from '../../src/lib/sql';

// -- ============================================================
// -- CHECK: BR06 – every friend_visit occurs inside an open member visit
// -- WHAT I'M TESTING: I am checking that, for each friend_visit,
// --   the member's most recent access event at that branch before
// --   the friend_visit is a check_in (not a check_out and not absent).
// --   The business rule states a friend can only come in together
// --   with the member; a friend_visit with no open visit means either
// --   a data error or an undocumented override.
// -- WHY: Unclosed or absent visits inflate friend-allowance counts
// --   and misrepresent member activity.
// -- EXPECTED: 0 rows.
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

export const check: Check = {
  id: 'BR06',
  name: 'Every friend visit happens while the member is checked in',
  severity: 'warning',
  sql: `
    WITH deduped AS (${DEDUPED_FIRST_DELIVERY}),
    fv AS (
      SELECT member_id, event_ts, branch_id, event_id
      FROM deduped
      WHERE lower(event_type) = 'friend_visit'
        AND ${REGISTERED_MEMBER}
    )
    SELECT
      fv.member_id,
      fv.branch_id,
      fv.event_ts          AS friend_visit_ts,
      last_ev.etype        AS last_access_event_at_branch
    FROM fv
    LEFT JOIN LATERAL (
      SELECT lower(event_type) AS etype
      FROM deduped
      WHERE member_id = fv.member_id
        AND branch_id  = fv.branch_id
        AND lower(event_type) IN ('check_in', 'check_out')
        AND event_ts  <= fv.event_ts
      ORDER BY event_ts DESC, event_id DESC
      LIMIT 1
    ) last_ev ON true
    WHERE last_ev.etype IS NULL
       OR last_ev.etype = 'check_out'
    ORDER BY fv.member_id, fv.event_ts
  `,
};
