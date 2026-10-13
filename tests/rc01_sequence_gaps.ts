import type { Check } from '../src/lib/types';

// -- ============================================================
// -- CHECK: RC01 – no missing sequence numbers in device source_refs
// -- WHAT I'M TESTING: I am checking that for each device the
// --   integer sequence embedded in source_ref is contiguous after
// --   dedup.  A gap means events were sent by the device but never
// --   arrived.  S1c (exploration) found D02-OUT missing 27 events.
// -- WHY: Missing sequences mean lost check-in or check-out events.
// --   They inflate the 'never closed' visit count and directly
// --   under-count visits at the affected branch.
// -- EXPECTED: 0 rows (gap_count = 0 for every device).
// -- SEVERITY IF IT FAILS: blocking
// -- ============================================================

export const check: Check = {
  id: 'RC01',
  name: 'No missing sequence numbers in any device source_ref stream',
  severity: 'blocking',
  kind: 'negative',
  sql: `
    WITH deduped AS (
      SELECT DISTINCT ON (source_ref) *
      FROM   events
      ORDER  BY source_ref, ingested_at ASC, event_id ASC
    ),
    seqs AS (
      SELECT
        device_id,
        split_part(source_ref, ':', 2)::bigint AS seq
      FROM   deduped
      WHERE  device_id IS NOT NULL AND device_id != ''
        AND  source_ref LIKE (device_id || ':%')
        AND  split_part(source_ref, ':', 2) ~ '^[0-9]+$'
    )
    SELECT
      device_id,
      min(seq)                              AS min_seq,
      max(seq)                              AS max_seq,
      count(*)                              AS received,
      (max(seq) - min(seq) + 1)             AS expected,
      (max(seq) - min(seq) + 1) - count(*)  AS gap_count
    FROM   seqs
    GROUP  BY device_id
    HAVING (max(seq) - min(seq) + 1) - count(*) > 0
    ORDER  BY gap_count DESC
  `,
};
