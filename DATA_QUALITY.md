# FitTrack data-quality findings

I found **12 issues** across two systems: the access-control devices and the
CRM. This page lists them worst-first, shows the query that proves each one,
explains the single root cause behind it, and ends with the questions I'd ask
each team and what I'd monitor from now on.

**How I prioritised:** (1) does it corrupt the required `visits_per_branch`
report, (2) is the check blocking or a warning, (3) how many rows or members are
affected. Priority and severity are separate on purpose — RC1 is "only" a
warning but is top priority, because the report is wrong without handling it.

**Two conventions used everywhere below:**
- Counts are measured **after de-duplicating on `source_ref`, keeping the first
  delivery** (`DISTINCT ON (source_ref) ... ORDER BY source_ref, ingested_at`).
- Local time = `event_ts AT TIME ZONE branches.timezone`.

Every finding maps to a check in `tests/`, so it is re-tested on every run.

---

## At a glance

| Pri | ID | What's wrong | Severity | Affected | Impact on the report |
|-----|----|----|----|----|----|
| 🔴 | RC1 | Access devices deliver every event more than once | warning | 3,756 extra rows | Over-counts visits unless de-duped first |
| 🔴 | RC2 | SF entrance (D07-IN) clock on Eastern, not Pacific | blocking | 1,535 rows | SF pairs are wrong for Jun–Aug 2024 |
| 🔴 | RC3 | Test cards 990001/990002 live in production | blocking | 828 events | +269 phantom visits if not excluded |
| 🔴 | RC8 | Austin exit (D02-OUT) silently dropped events | blocking | 27 lost | 27 branch-2 visits never close |
| 🟠 | RC7 | One corrupt member-import batch (Apr 2024) | blocking | 5 members | Dropped from active counts & branch joins |
| 🟠 | RC9 | Re-join creates a 2nd member_id (duplicate person) | blocking | 10 members | One person counted twice |
| 🟠 | RC5 | CRM cancellations ingested up to 32 days late | warning | 344 of 420 | Cancelled members look active meanwhile |
| 🟠 | RC12 | `members` snapshot drifts from the event stream | warning | 49 + 8 | Wrong status/tier if snapshot is trusted |
| 🟠 | RC11 | Friend visits not checked against presence or tier | warning | 73 + 71 | Guest/allowance reports unreliable |
| 🟡 | RC4 | Austin entrance sent `CHECK_IN` (uppercase) | warning | 181 rows | Under-counts unless matched case-insensitively |
| 🟡 | RC6 | Active members with no CRM history at all | warning | 2 members | Omitted from event-derived reports |
| 🟡 | RC10 | Malformed member emails | warning | 4 members | Blocks CRM outreach only |

**Severity meaning.** *blocking* = must be clean on a correct database; it fails
the test run. Five blocking checks fail on *this* dataset on purpose — the suite
is a gate and stays red until the data is fixed; it passes on a clean database
with the same schema. *warning* = surfaced and counted, but doesn't fail the run.
Current result: **29 checks (+3 exploratory): 16 passed, 8 warnings, 5 blocking
failures.**

---

## Access-control devices & delivery pipeline

### 🔴 RC1 — Devices deliver every event more than once
`rc04` + de-dup in every access check · warning · 3,736 groups / 3,756 extra rows

Every one of the 24 access devices re-sends events; **no CRM event is ever
duplicated.** The re-delivered copy carries the *batch re-delivery time* in
`event_ts`, not the original scan time — so a naive de-dup that keeps the *last*
copy invents off-hours events and backwards visit pairs. Keeping the **first**
delivery is mandatory, and is the first step of the report.

```sql
SELECT source_ref, count(*)
FROM   events GROUP BY source_ref HAVING count(*) > 1;   -- 3,736 groups, all device-sourced
```
**Impact:** without first-delivery de-dup the report over-counts by thousands of
pairs. Handled in `visits_per_branch.sql`.

### 🔴 RC2 — SF entrance (D07-IN) ran on Eastern time
`rc02` · blocking · 1,535 rows, 2024-06-06 → 2024-08-06

For two months the San Francisco entrance stamped events ~3h **ahead** of when
they were received — Eastern time on a Pacific device. One bug, three symptoms:
impossible `event_ts > ingested_at`, phantom off-hours check-ins, and backwards
(check-in after check-out) SF pairs.

```sql
SELECT device_id, count(*), min(event_ts), max(event_ts)
FROM   events WHERE event_ts > ingested_at + interval '5 minutes'
GROUP  BY device_id;             -- only D07-IN
```
**Impact:** SF visit pairing is unreliable for Jun–Aug 2024. Blocking — it
silently distorts both counts and durations for one branch.

### 🔴 RC8 — Austin exit (D02-OUT) dropped events
`rc01` · blocking · 27 missing sequences

`source_ref` is `<device_id>:<sequence>`. D02-OUT's sequence runs 1 → 9,948 but
only 9,921 values arrived: **27 check-outs were generated and never ingested.**
This is the main driver of the long-standing "~890 more check-ins than
check-outs" gap — lost exits leave visits that never close.

```sql
WITH deduped AS (SELECT DISTINCT ON (source_ref) * FROM events
                 ORDER BY source_ref, ingested_at, event_id)
SELECT device_id, (max(seq)-min(seq)+1) - count(*) AS gap
FROM  (SELECT device_id, split_part(source_ref,':',2)::bigint AS seq
       FROM deduped WHERE source_ref LIKE device_id||':%') s
GROUP BY device_id HAVING (max(seq)-min(seq)+1)-count(*) > 0;   -- D02-OUT: 27
```
**Impact:** up to 27 real branch-2 visits can't be paired. Blocking — silent
under-counting we can't recover from the data.

### 🟡 RC4 — Austin entrance sent `CHECK_IN` in uppercase
case-insensitive matching in every check · warning · 181 rows, 2024-04-08 → 15

A one-week config window at D04-IN wrote `CHECK_IN` instead of `check_in`.

```sql
SELECT event_type, count(*)
FROM   events WHERE event_type <> lower(event_type) GROUP BY event_type;  -- CHECK_IN: 181
```
**Impact:** a case-sensitive filter would drop all 181. Handled — every check
compares `lower(event_type)`.

---

## Provisioning / test data

### 🔴 RC3 — Test cards 990001 and 990002 are live in production
`member_id IN (SELECT member_id FROM members)` filter in every access check · blocking · 828 events

Two IDs appear in `events` but not in `members`, with no membership history,
scanning all year across branches — clearly test or maintenance cards left on.

```sql
SELECT member_id, lower(event_type), count(*)
FROM   events WHERE member_id NOT IN (SELECT member_id FROM members)
GROUP  BY 1,2;                   -- 990001, 990002: 828 events
```
**Impact (measured):** they would add **269 phantom visit-pairs**. The report
counts registered members only, so the 70,721 total already excludes them.

---

## CRM: membership lifecycle & sync

### 🟠 RC7 — One corrupt member-import batch, April 2024
`gen05` (status enum) + `gen04` (home-branch FK), both blocking · 5 members: 1803, 1806, 1807, 1811, 1820

These five rows are **one bad import, not five coincidences** — each has
`status='Active'` (wrong case), `home_branch_id=9` (no such branch; valid 1–8),
and joined in a tight window 2024-04-15 → 04-28 with near-consecutive IDs.

```sql
SELECT member_id, status, home_branch_id, joined_on
FROM   members
WHERE  status NOT IN ('active','cancelled')
   OR  home_branch_id NOT IN (SELECT branch_id FROM branches);   -- same 5 rows
```
**Impact:** a case-sensitive `status='active'` filter drops them from active
counts; any join on `home_branch_id` drops them entirely. Blocking on both
counts (enum + referential integrity).

### 🟠 RC9 — Re-joining creates a duplicate member identity
`gen03` (email uniqueness) · blocking · 5 email pairs / 10 members

Five emails each sit on two member rows. Not random: each pair is one **older,
mostly `cancelled`** member and one of the **highest IDs in the table
(2118–2122), `active`**, same email/tier/branch. A returning member got a
**new `member_id` instead of a reactivated record.** One pair (1736/2118) is
`active` twice — a live duplicate.

```sql
SELECT email, array_agg(member_id ORDER BY member_id)
FROM   members WHERE email IS NOT NULL AND email <> ''
GROUP  BY email HAVING count(*) > 1;      -- 5 emails, IDs 2118-2122 reused
```
**Impact:** one person counted as two; lifecycle/active reports double-count and
visits split across two IDs. The CRM-side twin of RC6 (no reactivation path).

### 🟠 RC5 — CRM cancellations arrive in a late batch
`rc03` · warning · 344 of 420 cancels > 7 days late, max 32 days

Every `membership_cancelled` event is ingested long after it happened — the
cancellation is real, the *ingestion* is batched and slow.

```sql
SELECT count(*) FILTER (WHERE ingested_at - event_ts > interval '7 days'),
       max(ingested_at - event_ts)
FROM   events WHERE lower(event_type) = 'membership_cancelled';   -- 344, 32 days
```
**Impact:** for up to a month the access system treats cancelled members as
active (they can still check in). Counting their visits is a deliberate report
decision — see `visits_per_branch.sql`.

### 🟠 RC12 — The `members` snapshot drifts from the events
`br02` (status, 49) + `br02b` (tier, 8) · warning

`members.status`/`membership_tier` are a snapshot kept on a slower path than the
event stream, so they lag: 49 members whose snapshot status disagrees with their
latest event (e.g. 1005: snapshot `active`, events say `cancelled`), and 8 whose
tier disagrees. One cause (snapshot vs event-sourced truth), fed by RC5 (late
cancels) and RC9 (split histories).

**Impact:** any report trusting the snapshot mis-states status for 49 and tier
for 8 — including the friend-allowance cap (RC11), which keys off tier.

### 🟡 RC6 — Active members with no CRM history
`br03` · warning · 2 members (1031, 1132)

Both are `active` and visit regularly but have **zero** membership events, so
their state can't be derived from the stream. Likely migrated/legacy accounts
whose opening event was never backfilled.

**Impact:** their visits still count (registered members), but event-derived
membership reports omit them.

### 🟡 RC10 — Malformed member emails
`gen02` · warning · 4 members

Scattered, not a batch: `meimorganexample.com` (no `@`), `ethan.garcia@` (no
domain), `n/a`, `maya.bell(at)example.com`. Ordinary data-entry errors.

**Impact:** none on visit counts; blocks CRM outreach to those 4.

---

## Access-control business logic

### 🟠 RC11 — Friend visits aren't checked against presence or tier
`br06` (orphan visits, 73) + `br07` (over allowance, 71) · warning

One missing rule — the turnstile logs a `friend_visit` without checking that the
sponsoring member is inside **and** within their monthly tier cap — gives two
symptoms: 73 friend visits with no open member visit (member already left, or
their check-in was lost, RC8), and 71 member-months over the cap (basic 2 /
standard 3 / premium 8).

```sql
-- allowance breach (see br07 for the full check)
SELECT member_id, local_month, tier, friend_visits, allowance
FROM   ... WHERE friend_visits > allowance;     -- 71 member-months
```
**Impact:** `visits_per_branch` counts member pairs only, so this doesn't change
it — but any guest/allowance report is unreliable until the rule is enforced.
Warning, not blocking: policy gaps, and some overage may be granted on purpose.

---

## Questions for the CRM team

1. **Cancellations (RC5):** why up to 32 days late — nightly/weekly batch? Can
   access control get a near-real-time cancellation feed so cards stop working
   promptly?
2. **Snapshot vs events (RC12):** which is the system of record — `members.*` or
   the event stream? What updates the snapshot, and why does it drift for 49/8?
3. **Re-registration (RC9):** is a new `member_id` on re-join by design? How are
   we meant to link the two identities (shared email? a `previous_member_id`) so
   we don't double-count?
4. **April import (RC7):** what loaded members 1803–1820 with `status='Active'`
   and `home_branch_id=9`? Does branch 9 exist in the CRM (a planned branch)? Can
   the batch be corrected and re-validated?
5. **No-history actives (RC6):** are 1031 and 1132 migrated/legacy accounts whose
   opening event was never backfilled?
6. **Email validation (RC10):** is email validated at entry? Four are unusable.

## Questions for the access-control team

1. **Duplicates (RC1):** devices deliver at-least-once — can we get an
   idempotency key, and confirm `source_ref` is stable? Re-deliveries overwrite
   `event_ts` with the batch time — can the original scan time be preserved?
2. **D07-IN clock (RC2):** how is device time set, is it NTP-synced to the branch
   timezone, and are other devices at risk? Can the Jun–Aug window be backfilled?
3. **Lost events (RC8):** D02-OUT dropped 27 events — is there delivery
   acknowledgement/retry, and are other devices dropping events silently?
4. **Uppercase (RC4):** what changed at D04-IN on Apr 8–15, and is event-type
   casing contractually fixed?
5. **Test cards (RC3):** what are 990001/990002 for, and can test/service cards
   use a reserved ID range or a flag so reporting can exclude them reliably?
6. **Friend enforcement (RC11):** does the turnstile check member presence and
   tier allowance before admitting a guest, or is `friend_visit` logged
   unconditionally?

## What I would monitor from now on

Each row is already a check, so it runs on every ingestion batch:

| Monitor | Check | Trips when |
|---|---|---|
| Events stamped ahead of ingestion, per device | `rc02` | a device clock drifts (RC2) |
| `source_ref` sequence gaps, per device | `rc01` | a device drops events (RC8) |
| CRM ingestion lag | `rc03` | a CRM event arrives > 7 days late (RC5) |
| Duplicate `source_ref` rate | `rc04` | CRM duplicates appear / device rate spikes (RC1) |
| Schema contract: nulls, enums, FKs, email uniqueness | `gen01`–`gen06` | a bad import or new enum value (RC7, RC9) |
| Snapshot vs event-derived status/tier | `br02`/`br02b` | snapshot drift grows (RC12) |
| Unknown member IDs in `events` | member filter | a new test/service card goes live (RC3) |
| Friend visits outside a visit / over allowance | `br06`/`br07` | enforcement gap widens (RC11) |
| Report total in range + one row per branch | `e2e01` | a load yields 0, test-only, or de-dup-failed totals |
| Per-branch monthly volume vs that branch's average | `exp03` | a branch goes silent in a month |

Two trends I'd also watch over time: the **check-in minus check-out gap per
branch** (rising → a device is dropping exits, RC8), and the **CRM ingestion-lag
distribution** (so a slipping batch job is caught before a month-end report).
