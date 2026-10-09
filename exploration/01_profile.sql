-- 1. Row counts
SELECT 'branches' t, count(*) FROM branches
UNION ALL SELECT 'devices', count(*) FROM devices
UNION ALL SELECT 'members', count(*) FROM members
UNION ALL SELECT 'events',  count(*) FROM events;

-- 2. Column types
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;

-- 3. All branches
SELECT * FROM branches ORDER BY branch_id;

-- 4. Devices per branch and kind
SELECT branch_id, kind, count(*) FROM devices GROUP BY 1,2 ORDER BY 1,2;

-- 5. Event types and time ranges
SELECT event_type, count(*), min(event_ts), max(event_ts)
FROM events GROUP BY 1 ORDER BY 1;

-- 6. Member status/tier distribution
SELECT status, membership_tier, count(*) FROM members GROUP BY 1,2 ORDER BY 1,2;

-- 7. One member's full story
SELECT event_id, source_ref, event_type, event_ts, branch_id, device_id, ingested_at, details
FROM events
WHERE member_id = (SELECT member_id FROM events WHERE event_type = 'friend_visit' LIMIT 1)
ORDER BY event_ts
LIMIT 40;
