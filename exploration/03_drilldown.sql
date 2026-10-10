-- D1a: duplicates by event type
WITH d AS (SELECT source_ref FROM events GROUP BY 1 HAVING count(*) > 1)
SELECT e.event_type, count(*) AS rows_in_dup_groups, count(DISTINCT e.source_ref) AS refs
FROM events e JOIN d USING (source_ref)
GROUP BY 1 ORDER BY 1;

-- D1b: duplicates by source (device or CRM)
WITH d AS (SELECT source_ref FROM events GROUP BY 1 HAVING count(*) > 1)
SELECT coalesce(nullif(e.device_id, ''), 'crm') AS source, count(*) AS rows_in_dup_groups
FROM events e JOIN d USING (source_ref)
GROUP BY 1 ORDER BY 2 DESC;

-- D1c: are duplicates identical copies (retries) or different content under the same ref?
SELECT count(*) AS dup_groups,
       count(*) FILTER (WHERE variants = 1) AS identical_content,
       count(*) FILTER (WHERE variants > 1) AS different_content,
       max(ingest_gap) AS max_gap_between_copies
FROM (
  SELECT source_ref,
         count(DISTINCT concat_ws('|', member_id, event_type, event_ts, branch_id, device_id, details::text)) AS variants,
         max(ingested_at) - min(ingested_at) AS ingest_gap
  FROM events GROUP BY 1 HAVING count(*) > 1
) x;

-- D2: who sends events "from the future" (ingested before event_ts)?
SELECT coalesce(nullif(device_id, ''), 'crm') AS source, count(*) AS n,
       min(event_ts - ingested_at) AS min_ahead, max(event_ts - ingested_at) AS max_ahead,
       min(event_ts) AS first_seen, max(event_ts) AS last_seen
FROM events WHERE ingested_at < event_ts
GROUP BY 1 ORDER BY 2 DESC;

-- D3: late arrivals (ingested more than 1 hour after the event)
SELECT coalesce(nullif(device_id, ''), 'crm') AS source, count(*) AS n,
       max(ingested_at - event_ts) AS max_lag,
       min(event_ts) AS first_seen, max(event_ts) AS last_seen
FROM events WHERE ingested_at - event_ts > interval '1 hour'
GROUP BY 1 ORDER BY 2 DESC;

-- D4a: orphan events (member_id not in members)
SELECT e.event_type, count(*) AS n, count(DISTINCT e.member_id) AS distinct_members,
       min(e.member_id) AS min_id, max(e.member_id) AS max_id,
       min(e.event_ts) AS first_seen, max(e.event_ts) AS last_seen
FROM events e
WHERE NOT EXISTS (SELECT 1 FROM members m WHERE m.member_id = e.member_id)
GROUP BY 1 ORDER BY 2 DESC;

-- D4b: member_id range in members, for comparison
SELECT min(member_id), max(member_id), count(*) FROM members;

-- D5: the 5 events before Pearl District opened
SELECT e.event_id, e.source_ref, e.member_id, e.event_type, e.event_ts,
       e.event_ts AT TIME ZONE b.timezone AS local_ts, e.device_id
FROM events e JOIN branches b USING (branch_id)
WHERE (e.event_ts AT TIME ZONE b.timezone)::date < b.opened_on
ORDER BY e.event_ts;

-- D6: outside-hours events by type and local hour
SELECT e.event_type, extract(hour FROM e.event_ts AT TIME ZONE b.timezone)::int AS local_hour, count(*)
FROM events e JOIN branches b USING (branch_id)
WHERE lower(e.event_type) IN ('check_in','check_out','friend_visit')
  AND (e.event_ts AT TIME ZONE b.timezone)::time NOT BETWEEN b.opens_at AND b.closes_at
GROUP BY 1,2 ORDER BY 1,2;

-- D7: the 2 members with no start event
SELECT m.member_id, m.joined_on, m.status, m.membership_tier,
       (SELECT string_agg(e.event_type, ', ' ORDER BY e.event_ts)
        FROM events e WHERE e.member_id = m.member_id) AS their_events
FROM members m
WHERE NOT EXISTS (SELECT 1 FROM events e
                  WHERE e.member_id = m.member_id AND e.event_type = 'membership_started');
