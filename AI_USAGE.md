# AI usage

## Tool

**Claude Code** (Anthropic's CLI, running Claude Opus), throughout. I kept a
project instructions file (`CLAUDE.md`) that fixed the environment and the
non-negotiable rules — source tables read-only, report queries must be one
standalone query that runs on a different database with the same schema, never
edit a committed exploration file — so the assistant stayed inside them.

## Who did what

I owned the direction and the decisions; the AI did most of the typing.

| Mine | The AI's |
| --- | --- |
| What to investigate, and in what order | Drafting the SQL and the TypeScript harness |
| Which business rules become checks, and what each asserts | Proposing candidate checks |
| Every severity call (blocking vs warning; running the suite as a gate) | Running queries against the database |
| The report's counting decisions (dedup first delivery, exclude test accounts, exclude unpaired check-ins, count cancelled-member visits) | First drafts of the write-ups |
| Structure, naming, and the final wording of check comments | — |

In short: the ideas and judgments are mine; the AI gave me speed and breadth of
first drafts. My job was deciding what was correct and catching where it wasn't.

## Where I corrected it

**1. De-duplication kept the wrong copy.**
The devices deliver every event more than once. The AI's first dedup kept the
*last*-ingested copy (`ORDER BY ingested_at DESC`). The result looked off, so I
made it test its own root-cause SQL — which exposed the bug: the re-delivered
copy carries the *batch re-delivery* timestamp, not the original scan time, so
keeping the last copy rewrote `event_ts` and invented "off-hours" events and
backwards visit pairs. I had it switch to the **first** delivery (`ASC`), now the
first step of every query and the report. The single most important fix in the task.

**2. Over-engineering the reporting year.**
For `visits_per_branch.sql` the AI leaned toward *deriving* the year ("latest year
in the data") as "most portable." I asked what the assignment actually said: it
says **2024**, explicitly. Deriving the year would silently report a different
year on another database — wrong against the spec. We kept the literal `2024` and
documented why it's an intentional business constant. My reading of the spec
caught the AI reaching past it.

**3. It fixed one file but not the others.**
After we corrected the dedup bug in exploration file 05, I asked whether it had
checked the *earlier* files for the same problem. It hadn't. That produced
`06_recheck.sql`, which proved the "double scan" counts I'd worried about (35
within 1 min, 543 within 5 min) were **100% artifacts of the old bug** — they
dropped to zero once the first-delivery copy was kept.

**4. A check that passed for the wrong reason.**
I asked the AI to confirm the membership test cases were covered. For "a
cancellation with no prior start", it claimed BR01 (a check it had written)
caught it. I made it prove that on synthetic sequences — and the row was *not*
flagged: SQL three-valued logic makes `prev_etype IN (...)` evaluate to NULL for
a first event, so `NOT (... OR NULL OR ...)` silently dropped it. The check was
green only because this dataset happens to contain no such case. We fixed it
with a NULL-safe sentinel; it now catches the orphan cancellation and still
passes on the real data. The lesson: a green check isn't proof — I only trust
one I've watched fail on a case it's supposed to catch.

## How I verified its output

- **Ran everything** — no SQL accepted without seeing it produce output.
- **Cross-checked counts** a second, independent way (e.g. 700 identical duplicate
  groups; 269 phantom test-account visits; the report total of 70,721).
- **Hand-checked the report** against a naive count and walked one branch by hand.
- **Re-ran the suite after every change** (including the `src/`+`tests/`
  restructure) to confirm results held and the gate still exited for the right
  reasons.
- **Treated surprising results as suspect** — which is exactly how the dedup bug
  and the artifact double-scans were caught rather than shipped.
