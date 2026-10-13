# FitTrack data-quality

A data-quality review of FitTrack's gym data — one Postgres database written by
two systems (a CRM and the access-control turnstiles). The repo holds a one-command
**test suite**, the required **report query**, the **findings** (`DATA_QUALITY.md`),
and the **investigation trail** (`exploration/`).

## Run it

Needs **Docker Desktop** (running) and **Node.js 18+**.

```bash
docker compose up -d --wait   # start Postgres 17 and load the data (first run only)
npm install                   # install the suite's dependencies
npm test                      # run every check
```

`npm test` connects to the database, runs every check, prints one line each, and
**exits non-zero if any blocking check fails** — so it works as a CI gate on every
new load.

## Running against a different database

The suite reads the standard Postgres environment variables, so it points at any
database with the same schema:

| Variable | `PGHOST` | `PGPORT` | `PGDATABASE` | `PGUSER` | `PGPASSWORD` |
| --- | --- | --- | --- | --- | --- |
| Default | `localhost` | `5432` | `fittrack` | `fittrack` | `fittrack` |

```bash
PGHOST=… PGPORT=… PGDATABASE=… PGUSER=… PGPASSWORD=… npm test
```

(If port 5432 is taken, set `FITTRACK_DB_PORT` before `docker compose up`.)

## What you'll see

| Tag | Meaning |
| --- | --- |
| `[PASS]` | clean — 0 violating rows |
| `[WARN]` | a **warning** check found rows; reported, does **not** fail the run |
| `[FAIL]` | a **blocking** check found rows (or errored); **fails the run** |
| `[INFO]` | an **exploratory** check; prints stats, never passes or fails |

The run prints a summary and exits `1` if there was any blocking failure, else `0`.

> **On this dataset, 5 blocking checks fail on purpose** (clock shift, lost events,
> duplicate member identities, a corrupt import batch). The suite is a gate and
> stays red until those are fixed; on a clean database with the same schema it
> passes. Details in `DATA_QUALITY.md`.

## Running the reports

Each report is one standalone query, run read-only. It touches only the source
tables (`events`, `branches`, `members`) — no views, functions, or temp tables —
so it runs as-is on any database with the same schema. Counting decisions are
documented in comments inside each `.sql`.

```bash
docker compose exec -T db psql -U fittrack -d fittrack -f - < reports/visits_per_branch.sql
# or, against any database using the PG* vars above:
psql -f reports/visits_per_branch.sql
```

## The checks

```
src/                 # harness
  runner.ts          #   runs every registered check, prints results, sets the exit code
  lib/               #   db connection (PG* vars) + Check types
tests/               # the checks (the deliverable)
  index.ts           #   the registry — every check is imported and listed here
  schema/            #   ┐
  business-rules/    #   │ one folder per category
  edge-cases/        #   │ (explained below)
  regression/        #   │
  e2e/               #   │
  exploratory/       #   ┘
```

Checks live in one folder per **category** — what the check is about. Reading the
folder names is meant to be enough to see the suite's coverage at a glance:

| Folder | What it means | Example |
| --- | --- | --- |
| `schema/` | **Contract checks.** Is the data even the right shape? Nulls in required fields, unknown enum values, broken foreign keys, duplicate IDs. | every member's status is `active` or `cancelled` |
| `business-rules/` | **The five rules from the assignment** (membership state, active-in-month, visits, friend allowance, local time) and their knock-on effects. | monthly friend visits don't exceed the tier allowance |
| `edge-cases/` | **Boundaries** where logic tends to break. | an event exactly at closing time counts as inside opening hours |
| `regression/` | **Guards for the specific bugs I found** (the root causes in `DATA_QUALITY.md`), so they can't come back unnoticed. | no device sends timestamps ahead of ingestion (the clock-shift bug) |
| `e2e/` | **End-to-end** — "e2e" means running the whole report pipeline and checking the final output, plus overall health signals. | the report returns one row per branch with a non-zero total |
| `exploratory/` | **Stats only.** These never pass or fail; they print numbers a human can skim for anything odd. | distribution of visit durations |

A check also has two attributes, independent of its folder:

- **`kind`** — how it behaves at runtime: `negative` (rows returned = violations,
  the default) · `positive` (rows returned = an expected-good condition is
  missing) · `edge-case` · `exploratory` (stats only, never blocks).
- **`severity`** — `blocking` (fails the run) or `warning` (reported only).

### Adding a check

1. Create `tests/<category>/<id>_<short_name>.ts`:

   ```ts
   import type { Check } from '../../src/lib/types';

   export const check: Check = {
     id: 'GEN07',
     name: 'Short human-readable description',
     severity: 'warning',        // 'blocking' | 'warning'
     kind: 'negative',           // optional; defaults to 'negative'
     sql: `SELECT … WHERE <violating condition>`,   // rows returned = a problem
     // params: [ … ]            // optional, bound as $1, $2, …
   };
   ```

2. Import it in `tests/index.ts` and add it to the `checks` array.
3. `npm test`.

Checks that need a tunable input read it from an environment variable with a
sensible default, so the suite always runs with no arguments:

| Variable | Default | Used by |
| --- | --- | --- |
| `CHECK_YEAR` | `2024` | access-events-in-year check |
| `MIN_ACTIVE_PER_MONTH` | `100` | active-members-per-month check |
| `MIN_TOTAL_VISITS` / `MAX_TOTAL_VISITS` | `50000` / `200000` | report volume check |

## Repository map

| Path | What it is |
| --- | --- |
| `docker-compose.yml`, `db/init/` | Postgres 17 service and seed data |
| `src/` | the test harness (runner + db/types) |
| `tests/` | the data-quality checks, one per file |
| `reports/` | report queries (`visits_per_branch.sql`) |
| `exploration/` | numbered investigation SQL and their saved outputs |
| `DATA_QUALITY.md` | findings by root cause, prioritised, with team questions and monitoring |
| `AI_USAGE.md` | how AI was used on this task |
| `ASSIGNMENT.md` | the original task |

## Time spent

Roughly **4–5 hours**.
