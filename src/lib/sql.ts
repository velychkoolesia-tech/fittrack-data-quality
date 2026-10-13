// Shared SQL fragments for the CHECKS in tests/.
//
// Centralised so a fix (e.g. the de-dup sort order) is made in exactly one
// place instead of being copy-pasted across ~16 check files — the kind of
// divergence that caused the original DESC/ASC de-dup bug.
//
// NOTE: the report queries in reports/ deliberately do NOT import these.
// The assignment requires each report to be one standalone query that does
// not depend on anything we created, so their duplication is intentional.

// First-delivery de-duplication by source_ref (root cause RC1: access
// devices deliver at-least-once).  Keep the EARLIEST-ingested copy: a
// re-delivered copy carries the batch re-delivery time in event_ts, not the
// original scan time.  Use as:  WITH deduped AS (${DEDUPED_FIRST_DELIVERY})
export const DEDUPED_FIRST_DELIVERY = `
      SELECT DISTINCT ON (source_ref) *
      FROM   events
      ORDER  BY source_ref, ingested_at ASC, event_id ASC
    `;

// Restrict to real members; member_ids absent from the members table are
// test/service cards (RC3).  Use as a WHERE / AND predicate.
export const REGISTERED_MEMBER = `member_id IN (SELECT member_id FROM members)`;
