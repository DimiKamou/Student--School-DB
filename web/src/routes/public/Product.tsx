import { Link } from 'react-router-dom'
import { Pill } from '../../components/Pill'
import { PublicShell } from './Landing'
import './public.css'

/**
 * The teacher's day, concretely. Every screen described here exists; the tables
 * below are static examples drawn in the product's own components so what a
 * visitor sees on this page is what they get after signing in.
 */

/** Same single-hue ramp the class heatmap uses. Magnitude only, never a rainbow. */
const RAMP = ['--seq-100', '--seq-200', '--seq-300', '--seq-400', '--seq-500', '--seq-600', '--seq-700']
function rampFor(pct: number) {
  const i = Math.min(RAMP.length - 1, Math.max(0, Math.round(pct * (RAMP.length - 1))))
  return { background: `var(${RAMP[i] ?? '--seq-100'})`, color: i >= 4 ? '#fff' : 'var(--text-primary)' }
}

const HEAT: { topic: string; pct: number; verdict: string; time: string; behind: number; marks: number }[] = [
  { topic: 'Moles & stoichiometry', pct: 0.40, verdict: 'below_external_benchmark', time: 'under_taught', behind: 19, marks: 246 },
  { topic: 'Ionic bonding', pct: 0.71, verdict: 'ok', time: 'time_adequate', behind: 3, marks: 208 },
  { topic: 'Rates of reaction', pct: 0.63, verdict: 'ok', time: 'time_adequate', behind: 6, marks: 154 },
  { topic: 'Titration technique', pct: 0.52, verdict: 'assessment_artefact', time: 'time_not_recorded', behind: 11, marks: 96 },
  { topic: 'Redox', pct: 0.58, verdict: 'insufficient_evidence', time: 'time_not_recorded', behind: 4, marks: 17 },
]

export default function Product() {
  return (
    <PublicShell>
      <section className="pub-hero">
        <p className="eyebrow pub-eyebrow">Product</p>
        <h1 className="pub-h1">Two minutes in. A week’s worth of judgement out.</h1>
        <p className="pub-lede">
          The deal is simple and it is the whole design. A teacher gives the system marks at question
          level as fast as they can type them, and gets back five things no gradebook can produce
          from a column of averages.
        </p>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">Going in</p>
        <h2 className="pub-h2">Entry that survives a Friday</h2>
        <p className="pub-p">
          The entry grid is the screen the product rests on, so it is built like a spreadsheet and
          not like a form. You open the class, you type. There is no Save button — marks autosave as
          you go, because teachers do not press Save, they close the laptop.
        </p>
        <div className="pub-grid two">
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Keyboard first</h3></div>
            <p className="pub-p">
              <span className="kbd">Enter</span> moves down the column — the order you actually read
              a pile of scripts in. <span className="kbd">Tab</span> moves across to the next
              question. Nothing needs the mouse.
            </p>
            <div className="row" style={{ gap: 8, marginTop: 12 }}>
              <span className="kbd">A</span><span className="muted">absent</span>
              <span className="kbd">X</span><span className="muted">not submitted</span>
              <span className="kbd">E</span><span className="muted">exempt</span>
            </div>
            <p className="pub-p">
              Single letters, because typing “absent” twenty-four times is not a product. Each is
              stored as its own status: none of them is a zero, and none of them drags an average.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Paste from Excel</h3></div>
            <p className="pub-p">
              Most departments already mark in a spreadsheet. Copy a rectangular block, click the
              first cell, paste — the block lands anchored at that cell, rows and columns intact.
              Marks above the maximum are flagged as you type rather than silently accepted.
            </p>
            <p className="pub-p">
              For a test where most of the class got an item right, set the common value once and tap
              only the exceptions. The system knows which marks were entered deliberately and which
              were defaulted in bulk, and weighs them accordingly when it looks for a gap.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Nothing to configure first</h3></div>
            <p className="pub-p">
              A mark and a date is a valid entry. No framework, no tags, no blueprint. That alone
              buys trajectory and individual gaps against the student’s own baseline. Pick one topic
              from a dropdown and the topic analytics switch on. Tag question groups and the
              diagnosis sharpens again. Each rung is optional and each one buys something specific.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Measured, not asserted</h3></div>
            <p className="pub-p">
              The grid records how long entry actually took, so “under two minutes for a set” is a
              number your school can check against its own staff rather than a claim on a website.
            </p>
          </div>
        </div>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">Coming back · screen 1</p>
        <h2 className="pub-h2">Worth your attention</h2>
        <p className="pub-p">
          The screen you land on. Two lists only: what needs your judgement, and what you still owe.
          Both are capped — five findings, whole-class ones first, because one action there helps
          everyone. A wall of every student who dipped once is how teachers learn to ignore the
          whole thing.
        </p>
        <div className="card" style={{ marginTop: 20 }}>
          <header>
            <h2>Worth your attention</h2>
            <span className="sub">Example. Whole-class findings first.</span>
          </header>
          <div>
            <div className="finding systemic">
              <Pill value="systemic" />
              <div style={{ flex: 1, minWidth: 200 }}>
                <div style={{ lineHeight: 1.35 }}>11C Chemistry is 22 points under the national facility on Moles &amp; stoichiometry</div>
                <div className="muted" style={{ fontSize: 'var(--t-small)', marginTop: 2 }}>
                  11C · 246 marks · received well under its planned teaching time
                </div>
              </div>
              <Pill value="under_taught" />
            </div>
            <div className="finding individual">
              <Pill value="individual" />
              <div style={{ flex: 1, minWidth: 200 }}>
                <div style={{ lineHeight: 1.35 }}>Nikos P. loses 30 points more than his class on Ionic bonding</div>
                <div className="muted" style={{ fontSize: 'var(--t-small)', marginTop: 2 }}>11C · 34 marks across 5 assessments</div>
              </div>
            </div>
            <div className="finding declining">
              <Pill value="declining" />
              <div style={{ flex: 1, minWidth: 200 }}>
                <div style={{ lineHeight: 1.35 }}>Sofia M.’s recent work in 10B Maths sits below her own earlier baseline</div>
                <div className="muted" style={{ fontSize: 'var(--t-small)', marginTop: 2 }}>10B · 61 marks · measured against the class’s own movement</div>
              </div>
            </div>
            <div className="finding">
              <Pill value="explained_by_absence" />
              <div style={{ flex: 1, minWidth: 200 }}>
                <div style={{ lineHeight: 1.35 }}>Yiannis K. missed 4 of 6 lessons on Titration technique</div>
                <div className="muted" style={{ fontSize: 'var(--t-small)', marginTop: 2 }}>11C · attendance accounts for the gap; not an ability finding</div>
              </div>
            </div>
          </div>
        </div>
        <p className="pub-p">
          Underneath it sits what is still to mark, counted against the register — so a class where
          nobody has been entered yet cannot masquerade as a class with nothing to do.
        </p>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">Coming back · screen 2</p>
        <h2 className="pub-h2">The class topic heatmap</h2>
        <p className="pub-p">
          One row per topic. Shading is the class average; the verdict column is what to do about it,
          in words. Colour never carries the meaning on its own — every cell is labelled and every
          verdict is a word with a glyph, so the table survives colour-blindness, a greyscale
          printout and a projector with the contrast turned down.
        </p>
        <div className="card" style={{ marginTop: 20 }}>
          <header>
            <h2>Topics · 11C Chemistry</h2>
            <span className="sub">Example data.</span>
          </header>
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>Topic</th>
                  <th align="right">Class avg</th>
                  <th>Verdict</th>
                  <th>Teaching time</th>
                  <th align="right">Behind</th>
                  <th align="right">Marks</th>
                </tr>
              </thead>
              <tbody>
                {HEAT.map((h) => (
                  <tr key={h.topic}>
                    <td>{h.topic}</td>
                    <td align="right">
                      <span className="heat-cell" style={rampFor(h.pct)}>{Math.round(h.pct * 100)}%</span>
                    </td>
                    <td><Pill value={h.verdict} /></td>
                    <td><Pill value={h.time} /></td>
                    <td className="num">{h.behind}</td>
                    <td className="num muted">{h.marks}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
        <ul className="pub-list">
          <li>
            <strong>Titration technique</strong> is not a student finding at all. Those questions
            barely discriminate between strong and weak candidates, so the honest conclusion is about
            the test, and the table says so rather than reporting eleven struggling chemists.
          </li>
          <li>
            <strong>Redox</strong> has seventeen marks behind it. That is not enough to judge, so no
            verdict is offered. The row still appears, because an empty row is information too.
          </li>
        </ul>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">Coming back · screen 3</p>
        <h2 className="pub-h2">The student profile</h2>
        <p className="pub-p">
          One page per student, and the page a tutor can actually open in a parents’ evening. A
          single-series chart of their marks over time — never two scales on one chart, which is the
          most misleading thing you can do to a reader — and beneath it the adjusted figures in a
          table where they can be read honestly.
        </p>
        <ul className="pub-list">
          <li><strong>Gaps by topic and by skill</strong>, each with the count of marks behind it and the interval, not a bare point estimate.</li>
          <li><strong>Trajectory</strong> measured against the class’s own movement, so a student keeping pace with a rising cohort reads as steady and one falling behind reads as falling behind.</li>
          <li><strong>Recency weighting</strong>, on a half-life of about six months: lost in September but fine now, and fine in September but lost now, are different findings and stop looking identical.</li>
          <li><strong>A pooling warning</strong> when a trajectory crosses grading systems. A student moving MYP → DP or ΓΕΛ → IB is the normal case in an international school, and the page says what that line is resting on.</li>
        </ul>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">Coming back · screen 4</p>
        <h2 className="pub-h2">Under-taught topic detection</h2>
        <p className="pub-p">
          A weak topic has three very different causes and they belong to three different people.
          Record lessons against topics — a register you probably keep anyway — and a systemic
          finding stops being an accusation and becomes a diagnosis.
        </p>
        <div className="scroll-x" style={{ marginTop: 18 }}>
          <table>
            <thead>
              <tr><th>What the data shows</th><th>Verdict</th><th>Whose problem</th></tr>
            </thead>
            <tbody>
              <tr>
                <td>Class weak, contact time as planned</td>
                <td><Pill value="time_adequate" /></td>
                <td className="secondary">Teaching and resources</td>
              </tr>
              <tr>
                <td>Class weak, 4 lessons delivered of 9 planned</td>
                <td><Pill value="under_taught" /></td>
                <td className="secondary">Curriculum design and the timetable</td>
              </tr>
              <tr>
                <td>Student weak, missed most of the unit</td>
                <td><Pill value="explained_by_absence" /></td>
                <td className="secondary">Attendance — not an ability deficit</td>
              </tr>
              <tr>
                <td>No lessons recorded against the topic</td>
                <td><Pill value="time_not_recorded" /></td>
                <td className="secondary">Nobody yet — time can’t be ruled in or out</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section className="pub-section">
        <p className="eyebrow pub-eyebrow">Coming back · screen 5</p>
        <h2 className="pub-h2">Report comments that cite the evidence</h2>
        <p className="pub-p">
          Reports week is where a term of question-level marks finally pays the teacher back
          personally. Your department’s comment bank, filtered to the band the student is actually
          in, drafted against what the data says — the topics they hold, the ones they don’t, the
          trajectory — and then edited by you. The draft records which bank entry it came from, so a
          department can see what its own house style has become.
        </p>
        <p className="pub-p">
          Nothing is ever sent on your behalf and nothing is published automatically. A comment
          leaves this system when a human presses a button.
        </p>
      </section>

      <section className="pub-section">
        <h2 className="pub-h2">Who sees what</h2>
        <p className="pub-p">
          Scope is enforced in the database, not in the screens, because a bug in a screen should
          never be able to become a breach. Teachers see the students they teach, tutors their
          tutees, students themselves, guardians their children. Each school is a separate tenant
          and no query can cross that line.
        </p>
        <p className="pub-p">
          Leadership views exist, and they are deliberately delayed: a teacher gets right of first
          sight of a systemic flag about their own class before it appears on a leadership screen.
          There are no teacher league tables, in any view, for anyone.
        </p>
        <div className="pub-actions">
          <Link to="/method" className="pub-btn">How the analytics work</Link>
          <Link to="/setup" className="pub-btn ghost">Set up your school</Link>
          <span className="pub-note">Already have an account? <Link to="/login">Sign in</Link>.</span>
        </div>
      </section>
    </PublicShell>
  )
}
