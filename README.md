# Student–School DB

An interactive database for schools that tracks student progress across grading
systems and identifies **which periods, topics and skills are dragging a student
down** — and whether the cause is that student or the teaching.

Built to work for IB MYP, IB DP, Greek Panhellenic and UK GCSE/A-Level
simultaneously, and to absorb a new national system without a migration.

## Status

Database layer, complete and validated. No application yet — see
[Build order](#build-order).

```
db/migrations/   001–009, all runnable against PostgreSQL 16
db/seed/         grading systems as configuration rows
db/test/         synthetic year with planted ground truth + assertions
docs/            ARCHITECTURE.md — the decisions and why
```

## Quick start

```bash
# needs a PostgreSQL 16 you can connect to
export PGHOST=/var/run/postgresql PGPORT=5433 PGUSER=postgres

./db/rebuild.sh          # schema + framework seeds
./db/test/run_tests.sh   # synthetic year + 9 assertions, all must PASS
```

## What makes this different from a gradebook

**Marks are stored at question/criterion grain.** "Maria dropped from 6 to 5" is
not a finding. "Maria loses 60% of available marks on integration items while her
cohort loses 15%" is.

**Individual gaps are separated from systemic ones.** A cohort failing a topic is
not twenty struggling students — it is a teaching, curriculum or timetable
problem, and the schema says which:

| Verdict | Meaning |
|---|---|
| `individual` | This student, against their own difficulty- and growth-adjusted baseline |
| `systemic` | The whole cohort, measured against an external benchmark |
| `systemic_and_individual` | Both |
| `explained_by_absence` | They missed the lessons; not an ability deficit |
| `assessment_artefact` | The questions don't discriminate; the finding is about the test |
| `insufficient_evidence` | Not enough data to say. Returned instead of a guess. |

**Teaching time is recorded**, so a weak topic can be attributed between *taught
badly*, *only got two lessons*, and *the student wasn't in the room*. Those are
three different findings for three different people.

**The entry cost is treated as the binding constraint.** A teacher records a mark
with zero configuration — no framework, no tags, no setup — and still gets
trajectory analytics. Each optional piece of structure unlocks more. If entry
takes more than about two minutes, no data accumulates and every analytic
downstream is decoration on an empty table.

## What it deliberately will not do

- **No teacher league tables.** The schema could express it. The moment a school
  can rank staff on this data, teachers stop entering honest formative marks.
- **No cohort-wide period effect without an external anchor.** "Everyone had a
  bad December" and "December's paper was harder" produce numerically identical
  data. The view reports `not_identifiable` rather than a confident number.
- **No confident verdict from thin evidence.** Every individual finding carries a
  confidence interval and an evidence count.
- **Absence is never scored as zero.**
- **No cross-framework averaging of unanchored scales.** A DP 6 and an MYP 6/8
  both normalise near 0.72 and are not the same standard.

## Build order

1. ✅ **Database layer** — schema, framework configuration, analytics, RLS, tests
2. **Framework seeds** — MYP and DP done; Greek Panhellenic and UK in progress
3. **API** — FastAPI or Node over the RPCs in `006_write_path.sql`, with
   `SET LOCAL` tenant context per request
4. **Teacher entry UI** — keyboard-first grid, paste-from-Excel, the
   "everyone got it, tap the exceptions" flow, blueprint cloning
5. **Teacher dashboard** — marking to-do, class topic heatmap, students who
   slipped, comment bank
6. **Leadership views** — curriculum audit, cohort trends, with right-of-first-sight delay
7. **Framework authoring UI** — so a school can add its own internal scheme
   without SQL

## Licence

Not yet chosen.
