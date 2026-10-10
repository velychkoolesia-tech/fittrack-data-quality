-- Reusable: inspect one member. Run with -v member_id=<id>

-- Summary: how many events of each type
SELECT event_type, count(*)
FROM events
WHERE member_id = :member_id
GROUP BY 1 ORDER BY 1;

-- Full timeline: one row per event
SELECT event_id, source_ref, event_type, event_ts, branch_id, device_id, ingested_at, details
FROM events
WHERE member_id = :member_id
ORDER BY event_ts, event_id;
