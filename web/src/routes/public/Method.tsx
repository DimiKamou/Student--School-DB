import { Link } from 'react-router-dom'
import { Pill } from '../../components/Pill'
import { PublicShell } from './Landing'
import './public.css'

/**
 * For the sceptic and for the head of department. Everything here is what the
 * analytics layer actually computes, including the limit it cannot get past --
 * which is stated plainly, because a school that has been sold education
 * analytics before will trust the page that names its own blind spot faster
 * than the one that doesn't have one.
 */

/* --- The three numbers, as a vertical flow so it stays legible at 400px --- */
function Decomposition() {
  const boxes: { title: string; value: string; sub: string }[] = [
    { title: 'pct', value: '0.62', sub: 'The raw score, normalised to 0–1.' },
    { title: 'd_adj', value: '+0.04', sub: 'Net of how hard the item was.' },
    { title: 'residual', value: '−0.11', sub: 'Also net of their own growth path.' },
  ]
  const arrows = ['− item mean (within the cohort)', '− (intercept + slope · t), per student']
  return (
    <figure className="pub-figure narrow">
      <svg className="chart" viewBox="0 0 360 268" role="img"
           aria-label="Raw score 0.62 minus the item mean gives a difficulty-adjusted +0.04; minus the student's own fitted growth path gives a residual of −0.11.">
        {boxes.map((b, i) => {
          const y = i * 96
          return (
            <g key={b.title}>
              <rect x={1} y={y} width={358} height={58} rx={8}
                    fill="var(--surface-1)" stroke="var(--border)" />
              <text x={16} y={y + 23} style={{ fill: 'var(--text-primary)', fontSize: 13, fontWeight: 650,
                    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace' }}>{b.title}</text>
              <text x={344} y={y + 23} textAnchor="end" className="tabular"
                    style={{ fill: 'var(--text-primary)', fontSize: 14, fontWeight: 650 }}>{b.value}</text>
              <text x={16} y={y + 43} className="axis-text">{b.sub}</text>
              {i < 2 && (
                <g>
                  <line x1={28} x2={28} y1={y + 58} y2={y + 88} stroke="var(--baseline)" strokeWidth={1} />
                  <polygon points={`28,${y + 94} 24,${y + 86} 32,${y + 86}`} fill="var(--baseline)" />
                  <text x={42} y={y + 79} className="axis-text">{arrows[i]}</text>
                </g>
              )}
            </g>
          )
        })}
      </svg>
      <figcaption>
        The item mean is estimated from what this cohort actually did with the question; the growth
        path is fitted per student. A student sitting above the item mean can still be below their
        own trend — which is the finding a term average cannot reach.
      </figcaption>
    </figure>
  )
}

/* --- The December dip: one line, two explanations, identical data ---------- */
function DecemberDip() {
  const pts: { label: string; v: number }[] = [
    { label: 'Sep', v: 0.68 }, { label: 'Oct', v: 0.66 }, { label: 'Nov', v: 0.67 },
    { label: 'Dec', v: 0.52 }, { label: 'Jan', v: 0.65 },
  ]
  const X0 = 34, X1 = 340, Y0 = 16, Y1 = 118
  const sx = (i: number) => X0 + (i / (pts.length - 1)) * (X1 - X0)
  const sy = (v: number) => Y1 - v * (Y1 - Y0)
  const d = pts.map((p, i) => `${i ? 'L' : 'M'}${sx(i).toFixed(1)},${sy(p.v).toFixed(1)}`).join(' ')
  return (
    <figure className="pub-figure">
      <svg className="chart" viewBox="0 0 360 150" role="img"
           aria-label="A class mean of about 67 percent in September to November, dropping to 52 percent in December, back to 65 percent in January.">
        {[0.5, 0.75, 1].map((t) => (
          <g key={t}>
            <line className="grid-line" x1={X0} x2={X1} y1={sy(t)} y2={sy(t)} />
            <text className="axis-text" x={X0 - 6} y={sy(t) + 4} textAnchor="end">{Math.round(t * 100)}%</text>
          </g>
        ))}
        <path className="series-line" d={d} />
        {pts.map((p, i) => (
          <g key={p.label}>
            <circle className="dot" cx={sx(i)} cy={sy(p.v)} r={4} />
            <text className="axis-text" x={sx(i)} y={136} textAnchor="middle">{p.label}</text>
          </g>
        ))}
        <text className="axis-text" x={sx(3)} y={sy(0.52) + 22} textAnchor="middle"
              style={{ fill: 'var(--text-primary)', fontWeight: 600 }}>52%</text>
      </svg>
      <figcaption>Class mean by month. One cohort, one subject, one teacher.</figcaption>
    </figure>
  )
}

export default function Method() {
  return (
    <PublicShell>
      <section className="pub-hero">
        <p className="eyebrow pub-eyebrow">Method</p>
        <h1 className="pub-h1">What the numbers are, and what they cannot see.</h1>
        <p className="pub-lede">
          Written for the person in the room who is going to ask the hard question. Nothing here is
          proprietary mystery: the adjustments are stated, the thresholds are stated, and the one
          thing this design structurally cannot separate is stated too.
        </p>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">1 · Grain</p>
        <h2 className="pub-h2">One row per scored slot, not per term</h2>
        <p className="pub-p">
          If the underlying table is <span className="pub-code">student × subject × term → grade</span>,
          you can draw a very pretty line and diagnose nothing. “Maria dropped from 6 to 5 in Maths”
          is not a finding. Marks are stored per question and per criterion, so “Maria loses 60% of
          the available marks on integration-by-parts items while her cohort loses 15%” is a finding
          — and it needs no new tables to ask.
        </p>
        <p className="pub-p">
          Derived results — an MYP level, a DP subject grade, a μόρια projection, a predicted GCSE —
          live in a separate table from observed marks. The most dangerous query in this domain adds
          a student’s question marks to the total derived from them; in one table that is a forgotten
          WHERE clause away, in two it cannot be written by accident.
        </p>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">2 · Adjustment</p>
        <h2 className="pub-h2">Item difficulty, then growth</h2>
        <p className="pub-p">
          A raw percentage confounds the student with the paper. Two adjustments are applied before
          anything is called a gap.
        </p>
        <Decomposition />
        <p className="pub-p">
          <strong>Item difficulty</strong> is estimated from what the cohort actually did with that
          question, not from a label someone typed. A question everyone found hard stops looking like
          a class of weak students.
        </p>
        <p className="pub-p">
          <strong>Growth</strong> matters more than it sounds. Model a student as a single year-long
          constant and Term 1 residuals come out systematically negative and Term 3 positive for
          every cohort in every subject — pure growth, reported as a period effect, in a report a
          head of year would have acted on. So each student carries their own fitted path and is
          compared to it.
        </p>
        <div className="pub-callout">
          <h3 className="pub-h3">Trajectory deliberately does not use the residual</h3>
          <p className="pub-p">
            The residual has the student’s own slope removed, so hunting for a trend in it is
            circular: a steadily declining student gets a fitted negative slope and residuals near
            zero, and the decline disappears. Trajectory is read from the difficulty-adjusted figure
            instead, which is already measured against the cohort’s own movement. This exact bug
            failed one of our regression assertions during development, which is why there is an
            assertion for it.
          </p>
        </div>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">3 · Confidence</p>
        <h2 className="pub-h2">An interval and a count, never a bare threshold</h2>
        <p className="pub-p">
          A classifier that thresholds a point estimate looks decisive and is wrong most of the time;
          the version of that we measured ran at roughly 25% precision. A noisy alert destroys
          adoption faster than any amount of typing, so an individual gap is only reported when a
          one-sided 95% interval on the adjusted difference stays below zero.
        </p>
        <pre className="pub-formula">{`mean_residual + 1.645 · se  <  0        ->  report a gap
se = max(sd, 0.05) / sqrt(n)            ->  a two-mark tag cannot fake precision
n < 8 responses                         ->  insufficient_evidence`}</pre>
        <ul className="pub-list">
          <li>The standard error is <strong>floored</strong>, so a tag with two suspiciously consistent marks cannot manufacture a tiny interval.</li>
          <li>Marks entered deliberately are counted separately from marks defaulted in bulk, because bulk defaults are weaker evidence about any individual.</li>
          <li>Recency is weighted on a half-life of about six months, so a gap closed in October stops being reported as a gap in May.</li>
          <li>Every finding on screen carries the number of marks behind it. If it says 17 marks, judge it as 17 marks.</li>
        </ul>
        <p className="pub-p">
          Where the evidence will not support a conclusion, the screen says so. That is not a spinner
          or an empty state — it is a verdict, with a name, that we chose to return instead of a
          number you would have believed.
        </p>
        <div className="row" style={{ gap: 8, marginTop: 12 }}>
          <Pill value="insufficient_evidence" />
          <Pill value="assessment_artefact" />
          <Pill value="no_baseline" />
          <Pill value="insufficient_recent_evidence" />
        </div>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">4 · The individual-versus-systemic test</p>
        <h2 className="pub-h2">Two different questions, two different comparisons</h2>
        <p className="pub-p">
          These are not two readings of one statistic. They use different comparisons, and one of
          them cannot be computed from a class’s own marks at all.
        </p>
        <div className="scroll-x" style={{ marginTop: 18 }}>
          <table>
            <thead>
              <tr><th>Verdict</th><th>Compared against</th><th>What it means</th></tr>
            </thead>
            <tbody>
              <tr>
                <td><Pill value="individual" /></td>
                <td className="secondary">The student’s own difficulty- and growth-adjusted baseline</td>
                <td>This student is behind on this topic relative to everything else they do.</td>
              </tr>
              <tr>
                <td><Pill value="systemic" /></td>
                <td className="secondary">An external anchor: a national facility, a published mean, an ΕΒΕ, anchor items</td>
                <td>The cohort is below expectation. A teaching, curriculum or timetable finding — not twenty struggling students.</td>
              </tr>
              <tr>
                <td><Pill value="systemic_and_individual" /></td>
                <td className="secondary">Both of the above</td>
                <td>The class is weak here and this student is weaker still. Both actions apply.</td>
              </tr>
              <tr>
                <td><Pill value="explained_by_absence" /></td>
                <td className="secondary">Attendance against the lessons for that topic</td>
                <td>They missed the lessons. Not an ability deficit, and never recorded as one.</td>
              </tr>
              <tr>
                <td><Pill value="assessment_artefact" /></td>
                <td className="secondary">How well the items separate strong from weak candidates</td>
                <td>These questions barely discriminate. The finding is about the test.</td>
              </tr>
              <tr>
                <td><Pill value="insufficient_evidence" /></td>
                <td className="secondary">—</td>
                <td>Not enough data to say. Returned instead of a guess.</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p className="pub-p">
          The systemic row is the one that needs the external anchor, and the reason is arithmetic:
          because item difficulty is estimated <em>within</em> the cohort, every within-class
          comparison is centred on that class’s own mean. A class taught badly on everything produces
          residuals that sum to zero and raises no flag at all. Only something from outside the class
          can see it. Benchmarks are therefore load-bearing here, not decoration, and the product asks
          your departments for them.
        </p>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">5 · The limit</p>
        <h2 className="pub-h2">What this design cannot tell you, ever</h2>
        <p className="pub-p">
          Here is a class mean by month. Something happened in December.
        </p>
        <DecemberDip />
        <div className="pub-grid two">
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Explanation A</h3></div>
            <p className="pub-p">
              The cohort really did have a bad December. Mock season, a long unit, three weeks of
              illness, a difficult period on the timetable.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Explanation B</h3></div>
            <p className="pub-p">
              December’s paper was simply harder than November’s. The students were fine.
            </p>
          </div>
        </div>
        <p className="pub-p">
          <strong>These two produce numerically identical data.</strong> Not similar — identical. In a
          balanced design the cohort-level mean residual is exactly zero, because subtracting the item
          mean removes anything common to the whole class along with the difficulty. We verify that
          in our own test suite. It is not a bug waiting to be patched; it is a property of estimating
          difficulty from the same students you are judging.
        </p>
        <p className="pub-p">
          So the cohort period view does not return a confident number. It returns its own
          identifiability, and where it cannot identify anything it says so in words:
        </p>
        <div className="pub-callout">
          <p className="pub-p" style={{ color: 'var(--text-primary)' }}>
            “No anchor items and no parallel class: a cohort-wide period effect cannot be separated
            from assessment difficulty in this data. Do not report one.”
          </p>
        </div>
        <ul className="pub-list">
          <li><strong>anchor_based</strong> — the assessments carried at least 30 responses on anchor items of known difficulty. The period effect is identified and reported.</li>
          <li><strong>cross_class_confounded</strong> — a parallel class sat the same assessment, so there is a contrast, but set allocation confounds it. Without prior attainment a lower mean may mean a lower-attaining set, not a worse term. Reported with that caveat attached, every time.</li>
          <li><strong>not_identifiable</strong> — neither. No number is produced.</li>
        </ul>
        <p className="pub-p">
          A period effect specific to <em>one student</em> is a different matter: “Maria had a bad Term
          2 relative to her peers and to her own trend” is identifiable, and it is reported. The
          distinction between those two claims is exactly the distinction this product is built on.
        </p>
        <p className="pub-p">
          If you want cohort-level period effects, the fix is in your assessment design rather than in
          our statistics: carry a handful of anchor items across papers, or hold one published
          benchmark per topic. We will tell you which of your data does and does not clear that bar.
        </p>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">6 · Across grading systems</p>
        <h2 className="pub-h2">A DP 6 and an MYP 6/8 are not the same standard</h2>
        <p className="pub-p">
          Both normalise near 0.72, and an engine that does not know better will happily average them.
          Every scale point carries its own anchor position rather than being assumed evenly spaced —
          GCSE 3→4 is not the same distance as 8→9 — and every scale records whether that position was
          ever checked against a real outcome distribution: assumed, anchored, or formally equated.
        </p>
        <p className="pub-p">
          When a student’s history crosses systems, the profile states which of those it is resting on
          and refuses to pool what should not be pooled. Criteria also keep a stable identity across
          syllabus reissues, so a school on a five-year MYP cycle does not silently lose its multi-year
          trend the day the guide changes.
        </p>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">7 · Evidence that it works</p>
        <h2 className="pub-h2">Tested against a year with planted answers</h2>
        <p className="pub-p">
          A schema that runs is not a schema that works. The engine is scored against a synthetic
          school year with known ground truth, on whether it finds what was planted <em>and stays
          quiet where nothing was</em> — the second half being the one that education analytics
          usually fails.
        </p>
        <div className="scroll-x" style={{ marginTop: 18 }}>
          <table>
            <thead><tr><th>Check</th><th>What it proves</th></tr></thead>
            <tbody>
              <tr><td>A</td><td>The planted individual gap is detected</td></tr>
              <tr><td>B</td><td>The planted cohort gap is detected</td></tr>
              <tr><td>C</td><td>The planted decline is detected</td></tr>
              <tr><td>C2</td><td>No spurious declines among the other 47 students</td></tr>
              <tr><td>D</td><td>The clean student is never flagged</td></tr>
              <tr><td>E</td><td>Under-taught context is attached to the systemic finding</td></tr>
              <tr><td>F</td><td>The cohort period effect declares its own confound</td></tr>
              <tr><td>G</td><td>A parallel class is not contaminated by its neighbour’s problem</td></tr>
              <tr><td>H</td><td>The individual flag rate stays low — currently 5.2%</td></tr>
            </tbody>
          </table>
        </div>
        <p className="pub-p">
          That last one is the number to hold us to. A system that flags a third of a year group has
          told you nothing and will be switched off by half term.
        </p>
        <div className="pub-actions">
          <Link to="/pricing" className="pub-btn">Pricing</Link>
          <Link to="/product" className="pub-btn ghost">What the teacher sees</Link>
        </div>
      </section>
    </PublicShell>
  )
}
