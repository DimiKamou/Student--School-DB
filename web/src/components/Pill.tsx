/**
 * A verdict badge. Colour NEVER carries the meaning alone: every pill pairs a
 * status colour with a glyph and a word, so it survives colour-blindness,
 * greyscale printing and forced-colors mode.
 */
const MAP: Record<string, { tone: string; glyph: string; label: string; title: string }> = {
  systemic: { tone: 'critical', glyph: '▲', label: 'Whole class',
    title: 'The cohort is below expectation here. This is a teaching, curriculum or time-allocation finding, not twenty struggling students.' },
  systemic_and_individual: { tone: 'critical', glyph: '▲', label: 'Class + student',
    title: 'The cohort is weak here AND this student is weaker still.' },
  individual: { tone: 'warning', glyph: '●', label: 'This student',
    title: 'Below their own difficulty- and growth-adjusted baseline, with the interval excluding zero.' },
  explained_by_absence: { tone: 'serious', glyph: '◐', label: 'Missed lessons',
    title: 'Attendance accounts for this gap. Not an ability deficit.' },
  assessment_artefact: { tone: 'neutral', glyph: '◇', label: 'Check the test',
    title: 'These questions barely discriminate. The finding is about the assessment, not the students.' },
  insufficient_evidence: { tone: 'neutral', glyph: '·', label: 'Not enough data',
    title: 'Too few observations to say anything honest.' },
  ok: { tone: 'good', glyph: '✓', label: 'On track', title: 'No gap detected.' },
  below_absolute_floor: { tone: 'critical', glyph: '▲', label: 'Below floor',
    title: 'Cohort mean is under the absolute floor for this topic.' },
  below_external_benchmark: { tone: 'critical', glyph: '▲', label: 'Below benchmark',
    title: 'Cohort is below the external benchmark for this topic.' },
  declining: { tone: 'warning', glyph: '↓', label: 'Declining', title: 'Recent work is below their earlier baseline.' },
  improving: { tone: 'good', glyph: '↑', label: 'Improving', title: 'Recent work is above their earlier baseline.' },
  stable: { tone: 'neutral', glyph: '→', label: 'Stable', title: 'No meaningful change.' },
  no_baseline: { tone: 'neutral', glyph: '·', label: 'No baseline', title: 'Not enough earlier work to compare against.' },
  insufficient_recent_evidence: { tone: 'neutral', glyph: '·', label: 'No recent data', title: 'Nothing recent enough to judge a trend.' },
  under_taught: { tone: 'serious', glyph: '◷', label: 'Under-taught',
    title: 'This topic received well under its nominal teaching time. A curriculum-design finding rather than a teaching one.' },
  time_adequate: { tone: 'neutral', glyph: '◷', label: 'Time adequate', title: 'Contact time was roughly as planned.' },
  time_not_recorded: { tone: 'neutral', glyph: '?', label: 'Time unknown', title: 'No lessons recorded against this topic, so time cannot be ruled in or out.' },
}

export function Pill({ value }: { value: string | null | undefined }) {
  if (!value) return null
  const m = MAP[value] ?? { tone: 'neutral', glyph: '·', label: value.replace(/_/g, ' '), title: value }
  return (
    <span className={`pill ${m.tone}`} title={m.title}>
      <span className="glyph" aria-hidden="true">{m.glyph}</span>
      {m.label}
    </span>
  )
}
