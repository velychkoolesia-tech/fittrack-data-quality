# FitTrack data-quality

A data-quality review of FitTrack's gym data (one Postgres database written by
two systems — a CRM and the access-control turnstiles). This repo contains:

- a **test suite** that checks the data against the business rules and the
  issues found during investigation (`tests/`);
- the required **report query** and layout for bonus reports (`reports/`);
- the **investigation trail** (`exploration/`) and the **findings write-up**
  (`DATA_QUALITY.md`).

## Prerequisites

- **Docker Desktop** (for the Postgres 17 container), running.
- **Node.js 18+** and npm (for the TypeScript test suite).

## Quick start

```bash
# 1. Start Postgres 17 and load the data (seeds from db/init on first run)
docker compose up -d --wait

# 2. Install the test-suite dependencies
npm install

# 3. Run the test suite
npm test
```

That's the whole loop. `npm test` connects to the database, runs every check,
prints one line per check, and exits non-zero if any **blocking** check fails.

## Database connection (environment variables)

The suite reads the standard Postgres environment variables, so it can be
pointed at **any** database with the same schema:

| Variable     | Default (local Docker) |
| ------------ | ---------------------- |
| `PGHOST`     | `localhost`            |
| `PGPORT`     | `5432`                 |
| `PGDATABASE` | `fittrack`             |
| `PGUSER`     | `fittrack`             |
| `PGPASSWORD` | `fittrack`             |

Against a different database:

```bash
PGHOST=... PGPORT=... PGDATABASE=... PGUSER=... PGPASSWORD=... npm test
```

The Docker container itself uses the same `fittrack`/`fittrack` credentials; set
`FITTRACK_DB_PORT` before `docker compose up` if port 5432 is already taken.

## Reading the output

Each check prints one line:

| Tag      | Meaning |
| -------- | ------- |
| `[PASS]` | check is clean (0 violating rows) |
| `[WARN]` | a **warning** check found rows — reported, does **not** fail the run |
| `[FAIL]` | a **blocking** check found rows (or errored) — **fails the run** |
| `[INFO]` | an **exploratory** check — prints sample stats, never passes/fails |

The run ends with a summary and exits `1` if there was any blocking failure,
`0` otherwise. This makes it usable as a pipeline gate.

> **Note on this dataset:** five blocking checks fail on the shipped data *on
> purpose* (clock shift, lost events, duplicate member identities, a corrupt
> import batch). The suite is a gate and stays red until those are fixed; on a
> clean database with the same schema it passes. See `DATA_QUALITY.md`.

## Running the report queries

Each report is a single standalone query, run read-only with `psql -f`:

```bash
# via the Docker container
docker compose exec -T db psql -U fittrack -d fittrack -f - < reports/visits_per_branch.sql

# or against any database with the same schema (uses the PG* vars above)
psql -f reports/visits_per_branch.sql
```

Report queries depend only on the source tables (`events`, `branches`,
`members`) — no views, functions, or temp tables — so they run as-is on a fresh
copy of this database or a different one with the same schema. Every counting
decision is documented in comments inside each `.sql` file.

## Test-suite layout and how to add a check

```
src/                   # the harness that runs the checks
  runner.ts            # runs every registered check, prints results, sets exit code
  lib/
    db.ts              # pg connection pool from PG* env vars
    types.ts           # Check / CheckResult types
tests/                 # the data-quality checks (the deliverable)
  index.ts             # the registry: every check is imported and listed here
  <id>_<name>.ts       # one check per file
```

A check is a small object. `severity` is `blocking` or `warning`; `kind` is
`negative` (rows = violations, the default), `positive` (rows = an expected-good
condition is missing), `edge-case`, or `exploratory` (stats only, never blocks).
Each file opens with a header comment stating what it tests, why, the expected
result, and the severity.

**To add a check:**

1. Create `tests/<id>_<short_name>.ts` exporting a `check: Check`:

   ```ts
   import type { Check } from '../src/lib/types';

   export const check: Check = {
     id: 'GEN07',
     name: 'Short human-readable description',
     severity: 'warning',          // 'blocking' | 'warning'
     kind: 'negative',             // optional; defaults to 'negative'
     sql: `SELECT ... WHERE <violating condition>`,  // rows returned = problem
     // params: [ ... ]            // optional, bound as $1, $2, ...
   };
   ```

2. Import it in `tests/index.ts` and add it to the `checks` array.
3. `npm test`.

Checks that take an input (e.g. a threshold or the reporting year) read it from
an environment variable with a sensible default, so the suite still runs with no
arguments — for example `MIN_ACTIVE_PER_MONTH`, `CHECK_YEAR`.

## Repository layout

| Path                | What it is |
| ------------------- | ---------- |
| `docker-compose.yml`, `db/init/` | Postgres 17 service and seed data |
| `src/`              | the test harness (runner + db/types) |
| `tests/`            | the data-quality checks (one per file, one command to run) |
| `reports/`          | report queries (`visits_per_branch.sql` + bonus) |
| `exploration/`      | numbered investigation SQL and their saved outputs |
| `DATA_QUALITY.md`   | findings by root cause, prioritised, with team questions and monitoring |
| `ASSIGNMENT.md`     | the original task |

## Time spent

Roughly **4–5 hours**.
