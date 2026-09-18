import type { ReactNode } from 'react'
import { Link, NavLink } from 'react-router-dom'
import { Pill } from '../../components/Pill'
import './public.css'

/**
 * The public site.
 *
 * A head teacher reads this before anyone signs in, and they have been sold
 * education analytics before. So the page leads with the one thing a gradebook
 * structurally cannot do -- tell a struggling student apart from a badly taught
 * topic -- shows it with numbers, and then states the limits as product
 * decisions rather than burying them in a footnote. Anyone who has been burned
 * by a dashboard that was confident and wrong reads the limits as the strongest
 * part of the pitch.
 *
 * The shell lives here rather than in its own file because this slice owns
 * exactly five files; Product, Method and Pricing import it.
 */

const NAV: { to: string; label: string }[] = [
  { to: '/product', label: 'Product' },
  { to: '/method', label: 'Method' },
  { to: '/pricing', label: 'Pricing' },
]

export function PublicShell({ children }: { children: ReactNode }) {
  return (
    <div className="pub">
      <header className="pub-bar">
        <Link to="/" className="pub-brand">Student–School DB</Link>
        <nav className="pub-nav">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} className={({ isActive }) => (isActive ? 'active' : '')}>
              {n.label}
            </NavLink>
          ))}
        </nav>
        <span className="pub-spacer" />
        <div className="pub-bar-actions">
          <Link to="/login" className="pub-signin">Sign in</Link>
          <Link to="/setup" className="pub-btn">Set up your school</Link>
        </div>
      </header>

      <main className="pub-main">{children}</main>

      <footer className="pub-foot">
        <div className="pub-foot-inner">
          <div style={{ minWidth: 200 }}>
            <div className="pub-brand" style={{ display: 'block', marginBottom: 8 }}>Student–School DB</div>
            <p className="muted" style={{ margin: 0, fontSize: 12.5 }}>
              Built by a practising IB MYP teacher. Hosted in the EU. Your marks stay your school’s
              property and leave in an open format whenever you ask.
            </p>
          </div>
          <span className="pub-spacer" />
          <nav>
            <Link to="/product">Product</Link>
            <Link to="/method">Method</Link>
            <Link to="/pricing">Pricing</Link>
            <Link to="/login">Sign in</Link>
            <Link to="/setup">Set up your school</Link>
          </nav>
        </div>
      </footer>
    </div>
  )
}

/* --- The worked example --------------------------------------------------
   Two bars and a dashed external benchmark. One hue, direct value labels, no
   second axis: the same rules the product's own charts follow. The verdict is
   never carried by the picture alone -- it is spelled out in a pill beside it.
   ------------------------------------------------------------------------- */
const X0 = 96, X1 = 290, BENCH = 0.62
const bx = (v: number) => X0 + Math.max(0, Math.min(1, v)) * (X1 - X0)

function Compare({ label, student, cohort, caption }:
  { label: string; student: number; cohort: number; caption: string }) {
  const rows: { name: string; v: number; fill: string }[] = [
    { name: 'This student', v: student, fill: 'var(--seq-500)' },
    { name: 'Class average', v: cohort, fill: 'var(--seq-200)' },
  ]
  return (
    <figure className="pub-figure" style={{ margin: 0 }}>
      <svg className="chart" viewBox="0 0 330 122" role="img"
           aria-label={`${label}. This student ${Math.round(student * 100)} percent, class average ${Math.round(cohort * 100)} percent, national facility ${Math.round(BENCH * 100)} percent.`}>
        {rows.map((r, i) => {
          const y = 18 + i * 36
          return (
            <g key={r.name}>
              <text className="axis-text" x={88} y={y + 14} textAnchor="end">{r.name}</text>
              <rect x={X0} y={y} width={Math.max(1, bx(r.v) - X0)} height={20} rx={3} fill={r.fill} />
              <text className="axis-text tabular" x={328} y={y + 14} textAnchor="end"
                    style={{ fill: 'var(--text-primary)', fontWeight: 600 }}>
                {Math.round(r.v * 100)}%
              </text>
            </g>
          )
        })}
        <line className="crosshair" x1={bx(BENCH)} x2={bx(BENCH)} y1={10} y2={92} />
        <text className="axis-text" x={bx(BENCH)} y={7} textAnchor="middle">National facility 62%</text>
        <line className="axis-line" x1={X0} x2={X1} y1={92} y2={92} />
        <text className="axis-text" x={X0} y={106}>0%</text>
        <text className="axis-text" x={X1} y={106} textAnchor="end">100%</text>
      </svg>
      <figcaption>{caption}</figcaption>
    </figure>
  )
}

export default function Landing() {
  return (
    <PublicShell>
      <section className="pub-hero">
        <p className="eyebrow pub-eyebrow">For schools running MYP, DP, Πανελλαδικές, GCSE and A-Level</p>
        <h1 className="pub-h1">Is it the student, or was the topic taught badly?</h1>
        <p className="pub-lede">
          Student–School DB records marks at question and criterion level, then tells you which
          periods, topics and skills are holding a student back — and whether the cause sits with
          that student or with the teaching. A gradebook cannot answer that question. It is the
          only question this one exists to answer.
        </p>
        <div className="pub-actions">
          <Link to="/setup" className="pub-btn big">Set up your school</Link>
          <Link to="/method" className="pub-btn ghost big">See how it works</Link>
          <span className="pub-note">Already have an account? <Link to="/login">Sign in</Link>.</span>
        </div>
        <div className="pub-chips">
          <span className="pub-chip">IB MYP</span>
          <span className="pub-chip">IB DP</span>
          <span className="pub-chip">Greek Panhellenic</span>
          <span className="pub-chip">UK GCSE / A-Level</span>
          <span className="pub-chip">Your own internal scheme</span>
        </div>
      </section>

      <section className="pub-section">
        <h2 className="pub-h2">The same low mark, two completely different jobs</h2>
        <p className="pub-p">
          Two Year 11 chemists, both under 50% on a topic. A gradebook shows you two red cells and
          leaves you to guess. Measured against what the rest of the class did on the same questions,
          and against a published national facility for that topic, they are not the same finding at
          all — and they land on different people’s desks.
        </p>

        <div className="pub-grid two">
          <div className="pub-card">
            <div className="pub-card-head">
              <h3 className="pub-h3">Aliki · Moles &amp; stoichiometry</h3>
              <Pill value="systemic" />
            </div>
            <Compare
              label="Moles and stoichiometry"
              student={0.49}
              cohort={0.40}
              caption="Aliki is above her class here. The class is 22 points under the national facility. Aliki is not the finding — the topic is."
            />
            <p className="pub-p">
              Intervening with Aliki would waste everyone’s time. Twenty-eight students need this
              topic retaught, and the class also received <strong>4 of a planned 9 lessons</strong> on
              it, so the honest label is curriculum design, not teaching quality.
            </p>
            <div className="row" style={{ gap: 8, marginTop: 10 }}>
              <Pill value="under_taught" />
              <span className="muted" style={{ fontSize: 12.5 }}>delivery ratio 0.44</span>
            </div>
          </div>

          <div className="pub-card">
            <div className="pub-card-head">
              <h3 className="pub-h3">Nikos · Ionic bonding</h3>
              <Pill value="individual" />
            </div>
            <Compare
              label="Ionic bonding"
              student={0.41}
              cohort={0.71}
              caption="Same subject, same term, same teacher. Here the class is fine and Nikos is 30 points behind it, on 34 marks across 5 assessments."
            />
            <p className="pub-p">
              This one is real and it is his. It survives adjustment for how hard the questions were
              and for his own upward trend elsewhere, and the 95% interval stays below zero. It is
              the finding that earns a conversation on Tuesday morning.
            </p>
            <div className="row" style={{ gap: 8, marginTop: 10 }}>
              <span className="muted tabular" style={{ fontSize: 12.5 }}>
                gap −0.19 · interval upper −0.06 · 34 marks
              </span>
            </div>
          </div>
        </div>

        <div className="pub-callout">
          <h3 className="pub-h3">Why no gradebook does this</h3>
          <p className="pub-p">
            A cohort failing a topic is not twenty struggling students, and the arithmetic that finds
            one hides the other. Class-relative statistics can see Nikos but are mathematically blind
            to Aliki’s class, because every within-class comparison is centred on that class’s own
            mean. Finding Aliki’s problem takes an external anchor — a national facility, a published
            mean, an ΕΒΕ, a parallel class. We ask for one, use it where it exists, and say so where
            it doesn’t.
          </p>
        </div>
      </section>

      <section className="pub-section">
        <h2 className="pub-h2">What it refuses to do, on purpose</h2>
        <p className="pub-p">
          Each of these is a thing the database could express and we decided it should not. They are
          the reason teachers keep entering honest formative marks after month three.
        </p>
        <div className="pub-grid three">
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">No teacher league tables</h3></div>
            <p className="pub-p">
              The moment staff can be ranked on this data, the marks stop being honest and the
              instrument dies. Teachers also get right of first sight: a systemic flag about your
              class reaches you before it reaches leadership.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Absence is never a zero</h3></div>
            <p className="pub-p">
              A missed test is missing data, not a score of nought. Where attendance accounts for a
              gap, the verdict says so instead of recording an ability deficit that isn’t there.
            </p>
            <div style={{ marginTop: 10 }}><Pill value="explained_by_absence" /></div>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">No verdict from thin evidence</h3></div>
            <p className="pub-p">
              Every individual finding carries a one-sided 95% interval and a count of the marks
              behind it. Under-powered comparisons return “not enough data” rather than a confident
              wrong answer you would have acted on.
            </p>
            <div style={{ marginTop: 10 }}><Pill value="insufficient_evidence" /></div>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">No unearned cross-system averages</h3></div>
            <p className="pub-p">
              A DP 6 and an MYP 6/8 both normalise near 0.72 and are not the same standard. Scales
              record whether their spacing was ever checked against a real distribution, and
              trajectories that cross frameworks say what they are resting on.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">No “everyone had a bad December”</h3></div>
            <p className="pub-p">
              A whole-cohort dip and a harder paper produce numerically identical data. Without
              anchor items or an external benchmark we report that it is not identifiable rather than
              invent a number. <Link to="/method">The full argument is on the Method page.</Link>
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">No setup before the first mark</h3></div>
            <p className="pub-p">
              A teacher can enter a mark with no framework, no tags and no configuration and still
              get trajectory analytics. Every extra piece of structure is optional and buys a
              specific extra finding.
            </p>
          </div>
        </div>
      </section>

      <section className="pub-section">
        <h2 className="pub-h2">It only works if entry is quick</h2>
        <p className="pub-p">
          Question-level marks are what make the diagnosis possible, and they are also what kills
          adoption if entry is slow. So entry is treated as the binding constraint on the whole
          product: a keyboard-first grid, single-letter codes for absent, not-submitted and exempt,
          and paste a block straight out of Excel. If a set of marks takes more than about two
          minutes, nothing accumulates and every analytic downstream is decoration on an empty table.
        </p>
        <div className="row" style={{ gap: 8, marginTop: 16 }}>
          <span className="kbd">Enter</span><span className="muted">next student</span>
          <span className="kbd">Tab</span><span className="muted">next question</span>
          <span className="kbd">A</span><span className="muted">absent</span>
          <span className="kbd">X</span><span className="muted">not submitted</span>
          <span className="kbd">E</span><span className="muted">exempt</span>
        </div>
        <div className="pub-actions">
          <Link to="/product" className="pub-btn ghost">See the teacher’s day</Link>
          <Link to="/pricing" className="pub-btn ghost">Pricing</Link>
        </div>
      </section>

      <section className="pub-section">
        <h2 className="pub-h2">Start with one department</h2>
        <p className="pub-p">
          A term of one subject’s marks is enough to see whether the findings are ones you recognise.
          Set your school up, invite the teachers who want in, and judge it on whether it told you
          something you did not already know.
        </p>
        <div className="pub-actions">
          <Link to="/setup" className="pub-btn big">Set up your school</Link>
          <Link to="/pricing" className="pub-btn ghost big">Talk to us about a year</Link>
        </div>
      </section>
    </PublicShell>
  )
}
