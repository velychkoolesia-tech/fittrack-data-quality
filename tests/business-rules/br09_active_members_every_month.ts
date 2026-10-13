import type { Check } from '../../src/lib/types';

// -- ============================================================
// -- CHECK: BR09 – every month in the dataset has active members
// -- WHAT I'M TESTING: I am verifying the "active in a month"
// --   business rule produces a non-zero result for every calendar
// --   month covered by the dataset.  A member is active in a month
// --   when their latest membership event up to the end of that
// --   month is membership_started or membership_reactivated.
// --   The month range is derived from the data, not hardcoded.
// -- WHY: Zero active members in any month means the active-members
// --   report would publish a zero that is either wrong (CRM data
// --   missing for that month) or correct but alarming (all members
// --   cancelled).  Either way it must be flagged.
// --   The minimum threshold ($1, default 100) is intentionally
// --   conservative; tune it for the expected population size.
// -- EXPECTED: 0 rows (every month has ≥ $1 active members).
// -- SEVERITY IF IT FAILS: warning
// -- ============================================================

const minActivePerMonth = parseInt(process.env.MIN_ACTIVE_PER_MONTH ?? '100', 10);

export const check: Check = {
  id: 'BR09',
  name: `Every month has at least ${minActivePerMonth} active members`,
  severity: 'warning',
  params: [minActivePerMonth],
  sql: `
    WITH month_series AS (
      -- Derive month range from CRM event data, no hardcoded dates
      SELECT generate_series(
        date_trunc('month', min(event_ts))::date,
        date_trunc('month', max(event_ts))::date,
        interval '1 month'
      )::date AS month_start
      FROM events
      WHERE lower(event_type) IN (
        'membership_started', 'membership_reactivated', 'membership_cancelled'
      )
    ),
    active_per_month AS (
      SELECT
        to_char(ms.month_start, 'YYYY-MM')    AS month,
        count(DISTINCT latest.member_id)       AS active_members
      FROM month_series ms
      JOIN LATERAL (
        SELECT DISTINCT ON (member_id)
          member_id,
          lower(event_type) AS last_event
        FROM   events
        WHERE  lower(event_type) IN (
                 'membership_started',
                 'membership_reactivated',
                 'membership_cancelled'
               )
          AND  event_ts < (ms.month_start + interval '1 month')::timestamp AT TIME ZONE 'UTC'
        ORDER  BY member_id, event_ts DESC, event_id DESC
      ) latest ON latest.last_event IN ('membership_started', 'membership_reactivated')
      GROUP  BY ms.month_start
    )
    SELECT month, active_members
    FROM   active_per_month
    WHERE  active_members < $1
    ORDER  BY month
  `,
};
