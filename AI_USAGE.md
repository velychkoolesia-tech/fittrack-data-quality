# AI usage

## Tools

I used **Claude Code** (Anthropic's CLI, running Claude Opus) throughout. I kept
a project instructions file (`CLAUDE.md`) that pinned down the environment, the
non-negotiable rules (source tables read-only; report queries must be one
standalone query that runs on a different database with the same schema; never
edit a committed exploration file), and the findings as they accumulated, so the
assistant stayed inside those constraints.

## How I worked with it

The division of labour was deliberate: **I owned the direction and the
decisions; the AI did most of the writing.**

- **Mine:** what to investigate and in what order; which business rules to turn
  into checks and what each check should assert; every severity call (blocking
  vs warning, and the decision to run the suite as a *gate* that stays red on the
  shipped data); the counting decisions in the report (de-dup first delivery,
  exclude test accounts by pattern, exclude unpaired check-ins, count
  cancelled-member visits); the file/structure choices; and the final wording of
  the check header comments, which I review and reword.
- **The AI's:** drafting the SQL and the TypeScript harness, proposing candidate
  checks, running queries against the database, and producing first drafts of the
  write-ups — all of which I then read, questioned, and corrected.

So the ideas and the judgments are mine; the AI accelerated turning them into
working SQL and code. The value it added was speed and breadth of first drafts;
the value I added was deciding what was correct and catching where it wasn't.

## Concrete cases where I corrected it

### 1. De-duplication kept the wrong copy (DESC → ASC)

The access devices deliver every event more than once. The assistant's first
de-dup kept the **last-ingested** copy (`ORDER BY ingested_at DESC`). I didn't
trust the result and had it test its own root-cause SQL. That surfaced the bug:
the re-delivered copy carries the *batch re-delivery* timestamp, not the original
scan time, so keeping the last copy was rewriting `event_ts` — which invented
"off-hours" events and backwards visit pairs (an implausible "~2% off-hours in
March/October" pattern was the tell). I had it switch to keeping the **first**
delivery (`ingested_at ASC`), which is now the first step of every query and the
report. This was the single most important correction in the whole task.

### 2. Over-engineering the reporting year

For `visits_per_branch.sql` the assistant leaned toward *deriving* the reporting
year ("the latest calendar year in the data") and presented that as the most
portable option. I asked what the assignment actually said about the year. It
says **2024**, explicitly and repeatedly ("members' visits in 2024"). So the
fixed literal `2024` was correct — deriving the year would have silently reported
a different year on a database holding other data, which is *wrong* against the
spec. We kept the literal 2024 and I had it document why it's an intentional
business constant (distinct from the forbidden dataset-specific hardcoding). A
case of my reading the spec catching the AI reaching past it.

### 3. It fixed one file but not the others

After we corrected the de-dup bug in exploration file 05, I asked whether it had
checked the **earlier** files for the same problem. It hadn't. That prompted
`06_recheck.sql`, which re-ran the affected integrity checks with the corrected
de-dup and proved that the "double scan" counts I'd been worried about (35 within
1 minute, 543 within 5 minutes) were **100% artifacts of the old bug** — they
dropped to zero once the first-delivery copy was kept. A real finding that only
came out because I didn't let it stop at the one file it had just touched.

## How I verified its output

- **Ran everything.** Every exploration query and every check was executed
  against the database; I didn't accept SQL I hadn't seen produce output.
- **Cross-checked counts.** Where a number mattered I confirmed it a second,
  independent way (e.g. the 700 byte-identical duplicate groups, the 269 phantom
  test-account visits, the 8-branch report total of 70,721).
- **Hand-checked the report.** I sanity-checked `visits_per_branch` against a
  naive count and walked one branch's pairing by hand.
- **Re-ran the suite after every change** (including the `src/` + `tests/`
  restructure) to confirm the results were unchanged and the gate still exited
  non-zero for the right reasons.
- **Treated surprising results as suspect**, not as answers — which is how the
  de-dup bug and the artifact double-scans were caught rather than shipped.
