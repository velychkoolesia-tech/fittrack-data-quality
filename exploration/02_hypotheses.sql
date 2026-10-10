-- H1: uppercase CHECK_IN - which devices, which dates?
SELECT device_id, branch_id, count(*), min(event_ts), max(event_ts)
FROM events WHERE event_type = 'CHECK_IN'
GROUP BY 1,2 ORDER BY 1;

-- H2: check-in vs check-out balance per branch
SELECT branch_id,
       count(*) FILTER (WHERE lower(event_type) = 'check_in')  AS check_ins,
       count(*) FILTER (WHERE event_type = 'check_out')        AS check_outs
FROM events GROUP BY 1 ORDER BY 1;

-- H3: access events by LOCAL year
SELECT extract(year FROM e.event_ts AT TIME ZONE b.timezone) AS local_year, count(*)
FROM events e JOIN branches b USING (branch_id)
WHERE lower(e.event_type) IN ('check_in','check_out','friend_visit')
GROUP BY 1 ORDER BY 1;

-- H5: members without a start event / with more than one / events for unknown members
SELECT 'no_start_event' AS check_name, count(*) FROM members m
WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.member_id = m.member_id AND e.event_type = 'membership_started')
UNION ALL
SELECT 'multiple_start_events', count(*) FROM (
  SELECT member_id FROM events WHERE event_type = 'membership_started' GROUP BY 1 HAVING count(*) > 1) x
UNION ALL
SELECT 'events_for_unknown_member', count(*) FROM events e
WHERE NOT EXISTS (SELECT 1 FROM members m WHERE m.member_id = e.member_id);

-- H6: events before the branch opened (local date)
SELECT b.branch_id, b.name, count(*)
FROM events e JOIN branches b USING (branch_id)
WHERE (e.event_ts AT TIME ZONE b.timezone)::date < b.opened_on
GROUP BY 1,2;

-- H7: access events outside opening hours, per branch (local time)
SELECT b.branch_id, b.name,
       count(*) FILTER (WHERE (e.event_ts AT TIME ZONE b.timezone)::time NOT BETWEEN b.opens_at AND b.closes_at) AS outside_hours,
       count(*) AS total
FROM events e JOIN branches b USING (branch_id)
WHERE lower(e.event_type) IN ('check_in','check_out','friend_visit')
GROUP BY 1,2 ORDER BY 1;

-- Duplicates: same source_ref ingested more than once
SELECT count(*) AS refs_duplicated, coalesce(sum(n - 1), 0) AS extra_rows
FROM (SELECT source_ref, count(*) n FROM events GROUP BY 1 HAVING count(*) > 1) d;

-- Device integrity: event type vs device kind
SELECT e.event_type, d.kind, count(*)
FROM events e LEFT JOIN devices d USING (device_id)
WHERE coalesce(e.device_id, '') <> ''
GROUP BY 1,2 ORDER BY 1,2;

-- Device integrity: event branch vs device's branch
SELECT count(*) AS branch_mismatch
FROM events e JOIN devices d USING (device_id)
WHERE e.branch_id <> d.branch_id;

-- Ingestion timing
SELECT count(*) FILTER (WHERE ingested_at < event_ts) AS ingested_before_event,
       max(ingested_at - event_ts) AS max_lag
FROM events;
