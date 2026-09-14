# Known gaps

Reported by the framework seeds while encoding four real grading systems onto
the schema. Fixed items are in `010_config_corrections.sql`. What remains is
recorded here rather than rediscovered later.

## Fixed in 010

| Gap | Fix |
|---|---|
| `equating_status` conflated arithmetic, tariff and distribution anchoring — the pooling guard was wrong in both directions | Four distinct values; `anchored_tariff` no longer licenses population comparison |
| GCSE has two national thresholds (grade 4 standard, 5 strong); `is_pass` boolean held one | `ref.scale_threshold` |
| Greek μόρια ×100 multiplier folded into weights, so published coefficients weren't literally readable | `conversion_rule.output_multiplier` |
| School target and model prediction both `role='predicted'` | `role IN ('target','baseline',...)` |
| A university department cut-off stored as `scope='national'` with a free-text label | `ref.institution`, `ref.admission_target`, `scope='institution'` |
| ΕΒΕ stored as a value with the eligibility rule only in prose | `ref.admission_gate` |
| ΕΠΙΣΤΗΜΟΝΙΚΟ ΠΕΔΙΟ / ΟΜΑΔΑ ΠΡΟΣΑΝΑΤΟΛΙΣΜΟΥ as opaque strings | `ref.pathway` + `ref.pathway_eligibility` |
| No statistic for a cumulative proportion at or above a grade (every UK outcome table) | `statistic='cum_proportion_at_or_above'` |
| Benchmarks that are grades, not numbers ("median A-Level grade is a B") | `benchmark.value_code` |

## Open, with the reasoning

**Per-question national facility data.** AQA Enhanced Results Analysis, Pearson
ResultsPlus and OCR Active Results give centres per-question national facility
values — the richest external data a UK school can obtain, and exactly what
`mv_cohort_tag` needs to detect a uniformly weak cohort. `ref.benchmark` keys to
a measure or a scale, never to an item. Needs an item-level benchmark table
keyed on a shared question identifier. **Highest-value open item.**

**Constructs are unique per framework, not per subject.** AQA Maths AO1 and AQA
English AO1 are different things; subject is currently packed into the construct
code (`MATH_AO1`). Works, but blocks a clean per-subject skill taxonomy.

**Dynamic input sets.** `conversion_input` is a static list, but "mean GCSE
points score" is the mean over whichever 8–11 GCSEs a student actually took. The
same shape applies to A-Level option blocks and BTEC optional units. Left to the
application deliberately — encoding per-student baskets declaratively would need
a query language in the config layer.

**Partial syllabus reductions.** `tag_inclusion.is_examinable` is boolean, but
Greek ύλη cuts are frequently partial ("χωρίς τις σελίδες 45–52"). Recorded as
whole ενότητες with the detail in `source_ref`.

**Two-stage Greek marking.** `(marker1 + marker2)/2` then `/5` cannot be written
as a conversion rule, because `conversion_input` keys on measure, not on marker
role. The data is held natively (`result.marker_role`), only the declarative
rule is missing.

**Cambridge time-zone variants.** Carried as a string convention in
`boundary_table.session_label` ('June 2024 variant 2') rather than a modelled
dimension.

**MYP subject-group criteria naming.** Handled via `measure.subject_group_code`,
which works but means the UI must know the group to label Criterion B correctly.

## Not gaps — deliberate refusals

- No view groups outcomes by teacher.
- No cohort-wide period effect without an anchor; see `ARCHITECTURE.md` §7.
- No confident verdict from thin evidence.
- Absence is never a zero.
