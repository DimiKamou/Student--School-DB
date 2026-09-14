# Architecture

## The question this database exists to answer

> Which periods, subjects, topics and skills are depressing this student's
> progress — and is the cause *this student* or *the teaching*?

Everything below follows from taking that question literally.

---

## 1. The decision everything else depends on: grain

If the fact table is `student × subject × term → grade`, the product can draw
pretty line charts and diagnose nothing. *"Maria dropped from 6 to 5 in Maths"*
is not a finding.

So marks are stored at **question / criterion grain**, in
`gradebook.result` — one row per scored slot per student. *"Maria loses 60% of
available marks on integration-by-parts items while her cohort loses 15%"* is a
finding, and it requires no new tables to ask.

## 2. Progressive structure

Grain at that level usually means a data-entry burden that kills adoption, and
with no data the analytics are decoration on an empty table. So structure is a
**ladder, and every rung above the first is optional**:

| Rung | What the teacher does | What unlocks |
|---|---|---|
| 0 | Enters a mark and a date. No framework, no tags, no setup. | Trajectory, individual gaps vs their own baseline |
| 1 | Picks one topic from a dropdown on the assessment | Topic-level analytics |
| 2 | Tags question groups | Content-level diagnosis |
| 3 | Tags per-item skills / AOs / criteria | Skill profile, cross-framework semantic view |

Rung 1 is a single nullable column, `gradebook.assessment.topic_tag_id` — not a
join table. The entry UI must never need to know a join table exists to buy the
cheapest possible attribution.

`org.teaching_group.framework_version_id` is nullable for the same reason.
Requiring framework configuration before the first keystroke is how this product
dies in pilot.

## 3. Grading systems are configuration, not code

Adding the French Baccalauréat must be `INSERT`s. The whole of MYP, DP,
Panhellenic and GCSE/A-Level is expressed in five tables:

```
ref.framework → ref.framework_version → ref.measure → ref.scale → ref.boundary_table
                        ref.construct ↗              ref.scale_point   ref.boundary_row
```

- **`ref.construct`** is the pedagogically stable identity *across versions*.
  When the MYP Sciences guide or an AQA spec is reissued, "Criterion B" and
  "AO3" become new `measure` rows. Without a stable construct id, every mark
  recorded under the old guide is unjoinable to the new one and the multi-year
  trend — the entire point of this database — silently resets at every spec
  change. A school on a 5-year MYP cycle hits this guaranteed.
- **`ref.scale_point.pct_anchor`** replaces the usual `n_points` column.

## 4. Why there is no `n_points` column

The conventional design stores `n_points` and normalises as
`(rank − 1) / (n_points − 1)`. Two things are wrong with it:

1. It is one hand-typed integer acting as the denominator of every normalisation
   in the system, with nothing tying it to the number of scale points that
   actually exist. One wrong integer mis-normalises an entire national system,
   silently.
2. It asserts **equal spacing**. GCSE 3→4 is not the same distance as 8→9. A DP
   6 and an MYP 6/8 are not the same standard, but both land near 0.72 and the
   engine will happily average them.

Instead every scale point carries its own `pct_anchor`, and
`ref.scale.equating_status` records whether that position was ever checked
against reality:

- `assumed_linear` — equal spacing, a guess. **Do not pool across frameworks.**
- `anchored` — set from a real outcome distribution.
- `equated` — formally equated to a common latent metric.

`analytics.v_pooling_check` enforces this per student, and the UI must respect
its verdict. A student moving MYP → DP or ΓΕΛ → IB is the normal case in
international schools; their trajectory has to cross that boundary *honestly*.

## 5. Two fact tables, not one

| Table | Holds |
|---|---|
| `gradebook.result` | **Observed**: a mark on a thing a student did |
| `gradebook.outcome` | **Derived / awarded**: MYP level, DP subject grade, μόρια projection, predicted GCSE |

The most dangerous query in this domain sums a student's question marks together
with the total derived from them. In one table with a `derivation` column that is
one forgotten `WHERE` away. In two tables it cannot be written by accident.

`gradebook.outcome` also keeps the MYP best-fit override in **one row**
(`suggested_value`, `raw_value`, `overrides_suggestion`, `rationale`), so
"we suggested 6, you chose 7" renders without a self-join — and the override
rate becomes a genuine analytic about teacher judgement.

## 6. What the analytics layer refuses to do

**Absence is never a zero.** `pct` is NULL unless `status='scored'`.

**No draft/publish gate.** An earlier design defaulted assessments to `draft` and
filtered analytics to `published`. A teacher could type 480 marks into a
permanently empty dashboard, with no error anywhere. `marking_closed_at` exists
but *no analytic filters on it*.

**No verdict from a point estimate.** Every individual gap carries a one-sided
95% interval and an evidence count. Underpowered comparisons return
`insufficient_evidence`, not a confident wrong answer.

**No teacher league tables.** The data would support it and the schema could
express it. The moment a school can rank staff on this database, teachers stop
entering honest formative marks and the instrument dies. `analytics.alert` gives
the teacher right of first sight (`visible_to_leadership_after`) before
leadership sees a systemic flag about their class.

## 7. The residual model, and what it cannot see

```
pct                                      raw score, normalised to [0,1]
d_adj    = pct − item_mean               difficulty-adjusted (item mean is within-cohort)
residual = d_adj − (intercept + slope·t) also growth-adjusted, per student
```

The growth term matters: modelling a student as a single year-long constant
makes Term 1 residuals systematically negative and Term 3 positive for **every**
cohort in **every** subject — pure growth, reported as a period effect.

### The identifiability limit

Item difficulty is estimated *within* the cohort, so `pct − item_mean`
mathematically removes any effect common to the whole class. In a balanced
design the term-level mean residual is **identically zero** — not small, not
noisy: exactly zero. This is verified in `db/test`.

That is not a bug to patch. It is a limit to respect:

- A period effect **specific to a student** is identifiable.
  `analytics.mv_student_period_effect` reports it.
- A period effect **common to the whole cohort** is *not* identifiable from that
  cohort's own marks. "Everyone had a bad December" and "December's paper was
  harder" produce numerically identical data.

`analytics.mv_cohort_period_effect` therefore carries an `identifiability`
column (`anchor_based` / `cross_class_confounded` / `not_identifiable`) and a
`caveat` string, instead of returning a confident zero. Separating the two needs
an external anchor: anchor items, a published benchmark, or a parallel class.

The same logic is why `ref.benchmark` is load-bearing rather than decorative. A
cohort taught badly on *everything* produces residuals summing to zero and raises
no flag; only an external anchor can see it. `analytics.mv_cohort_tag` joins it.

### Trajectory uses `d_adj`, never `residual`

`residual` has the student's own fitted slope removed, so looking for a trend in
it is circular — a steadily declining student gets a fitted negative slope and
residuals near zero. This exact bug failed assertion C during development.
`d_adj` is already measured against the cohort's own movement, so a student
keeping pace sits near zero and one falling behind goes negative.

## 8. Attribution: teaching, time, or absence

A weak topic has three very different causes, and a platform that cannot
separate them will confidently blame the wrong party:

| Cause | Evidence | Finding type |
|---|---|---|
| Taught badly | cohort weak, contact time adequate | Teaching |
| Never got the hours | cohort weak, `delivery_ratio < 0.6` | Curriculum design |
| Student wasn't there | `v_topic_attendance.missed_ratio > 0.3` | Neither |

Hence `org.lesson` (contact time per topic) and `org.lesson_attendance`.
`mv_gap_signal` returns `explained_by_absence` rather than an ability deficit
when attendance accounts for the gap, and carries `time_context` alongside every
systemic verdict.

## 9. Multi-tenancy

Tenant **is** the school. A group buying three schools gets three tenants.

Shared schema + `tenant_id` + Row-Level Security. Schema-per-tenant was rejected:
migrating 300 schemas on every release is the ops failure that kills small SaaS
teams.

Two independent RLS gates, both in the database because an ORM bug must not
become a cross-school breach:

1. **Tenant** — `tenant_id = app.current_tenant()`, applied to every table
   carrying the column, generated in a loop so a new table cannot be forgotten.
2. **Scope** — `app.can_see_student()`: teachers see students they teach, tutors
   their tutees, students themselves, guardians their children.

The app server must use `SET LOCAL` (never `SET`) so context dies with the
transaction and cannot leak across a pooled connection.

Materialized views cannot carry RLS, so they are **not** granted to the app
roles. The API reads them through `SECURITY DEFINER` functions that re-apply
scope. Granting them directly would be a scope bypass wearing a materialized
view.

## 10. Validation

`db/test/run_tests.sh` builds a synthetic school year with planted ground truth
and scores the engine on whether it finds it *and stays quiet where nothing was
planted*.

| Assertion | Checks |
|---|---|
| A | Planted individual gap detected |
| B | Planted cohort gap detected |
| C | Planted decline detected |
| C2 | No spurious declines among the other 47 students |
| D | Clean student never flagged |
| E | Under-taught context attached to the systemic finding |
| F | Cohort period effect declares its own confound |
| G | Parallel class not contaminated by its neighbour's problem |
| H | Individual flag rate stays low (currently 5.2%) |

A schema that runs is not a schema that works.
