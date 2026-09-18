import { Link } from 'react-router-dom'
import { PublicShell } from './Landing'
import './public.css'

/**
 * Per-school annual subscription. No prices are invented here: the tiers are
 * explicitly marked as placeholders and every call to action goes to a
 * conversation. Publishing a number we have not committed to would be exactly
 * the kind of confident-but-unfounded figure the rest of the product refuses
 * to render.
 */

type Tier = {
  name: string
  who: string
  points: string[]
  cta: string
  to: string
  feature?: boolean
}

const TIERS: Tier[] = [
  {
    name: 'Pilot',
    who: 'One department, one term.',
    points: [
      'Unlimited teachers in that department',
      'Every analytic switched on, nothing held back for a higher tier',
      'Your data exported in full at the end, whatever you decide',
      'Ends by default — no auto-renewal into a subscription',
    ],
    cta: 'Start a pilot',
    to: '/setup',
  },
  {
    name: 'School',
    who: 'One school, one academic year.',
    points: [
      'Every teacher, tutor and leader in the school',
      'All grading systems in use at once — MYP, DP, Πανελλαδικές, GCSE, A-Level',
      'Your own internal schemes added as configuration, not custom code',
      'Leadership views with teacher right-of-first-sight',
      'Support from the person who built it and teaches with it',
    ],
    cta: 'Talk to us',
    to: '/setup',
    feature: true,
  },
  {
    name: 'Group',
    who: 'Several schools under one trust or owner.',
    points: [
      'Each school is a separate tenant — no query can cross between them',
      'Per-school pricing, agreed for the group',
      'Group-level reporting only where every school has agreed to it',
      'No cross-school teacher comparison. Not at any price.',
    ],
    cta: 'Talk to us',
    to: '/setup',
  },
]

export default function Pricing() {
  return (
    <PublicShell>
      <section className="pub-hero">
        <p className="eyebrow pub-eyebrow">Pricing</p>
        <h1 className="pub-h1">One price per school, per year.</h1>
        <p className="pub-lede">
          Not per teacher and not per seat. A licence that charges by the teacher is a licence that
          quietly discourages the teachers you most want entering marks, and this product is worth
          nothing to you if half a department stays out of it.
        </p>
      </section>

      <section className="pub-section first">
        <div className="row" style={{ gap: 10 }}>
          <span className="pub-placeholder">Placeholder tiers</span>
          <span className="muted" style={{ fontSize: 12.5 }}>
            Figures are not published yet. Nothing below is a quote.
          </span>
        </div>
        <div className="pub-grid three">
          {TIERS.map((t) => (
            <div key={t.name} className="card pub-card pub-tier"
                 style={t.feature ? { borderColor: 'var(--series-1)' } : undefined}>
              <div className="pub-card-head">
                <h3 className="pub-h3">{t.name}</h3>
                {t.feature && <span className="pub-chip">Most schools</span>}
              </div>
              <p className="pub-p tight">{t.who}</p>
              <div className="pub-price">Price on request</div>
              <div className="pub-per">
                {t.name === 'Pilot' ? 'One-off, per term' : 'Per school, per academic year'}
              </div>
              <ul className="pub-list plain">
                {t.points.map((p) => (
                  <li key={p}><span className="tick" aria-hidden="true">✓</span><span>{p}</span></li>
                ))}
              </ul>
              <Link to={t.to} className={`pub-btn${t.feature ? '' : ' ghost'}`}>{t.cta}</Link>
            </div>
          ))}
        </div>
        <p className="pub-p">
          The band a school lands in follows students on roll, not the number of staff who log in.
          Whatever it turns out to be, it is agreed in writing before any data is loaded, and it does
          not change mid-year.
        </p>
      </section>

      <section className="pub-section">
        <h2 className="pub-h2">What every tier includes</h2>
        <p className="pub-p">
          There is no analytics feature held back for a higher plan. A school paying the smallest
          amount still gets the individual-versus-systemic verdict, because that is the product; a
          version of it with the honest parts removed would be a gradebook.
        </p>
        <div className="pub-grid two">
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Included, always</h3></div>
            <ul className="pub-list plain">
              <li><span className="tick" aria-hidden="true">✓</span><span>Question- and criterion-level entry, keyboard-first, paste from Excel</span></li>
              <li><span className="tick" aria-hidden="true">✓</span><span>Attention list, class topic heatmap, student profiles</span></li>
              <li><span className="tick" aria-hidden="true">✓</span><span>Under-taught topic detection and absence attribution</span></li>
              <li><span className="tick" aria-hidden="true">✓</span><span>Report comments drafted from your own comment bank</span></li>
              <li><span className="tick" aria-hidden="true">✓</span><span>Every grading system you run, simultaneously</span></li>
              <li><span className="tick" aria-hidden="true">✓</span><span>Full export of your data, at any time, in an open format</span></li>
            </ul>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">Never, at any tier</h3></div>
            <ul className="pub-list plain">
              <li><span className="cross" aria-hidden="true">✕</span><span>Teacher league tables or any staff ranking view</span></li>
              <li><span className="cross" aria-hidden="true">✕</span><span>A confident verdict the evidence does not support</span></li>
              <li><span className="cross" aria-hidden="true">✕</span><span>Absence scored as a zero</span></li>
              <li><span className="cross" aria-hidden="true">✕</span><span>Your marks used to train anything, or sold, or shared with a third party for their purposes</span></li>
              <li><span className="cross" aria-hidden="true">✕</span><span>Per-teacher seat fees that keep staff out of the system</span></li>
            </ul>
          </div>
        </div>
      </section>

      <section className="pub-section">
        <h2 className="pub-h2">Where the data lives, and whose it is</h2>
        <div className="pub-grid two">
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">EU hosting</h3></div>
            <p className="pub-p">
              Your school’s data is stored and processed in the European Union. If that ever needs to
              change for a specific school, it changes with that school’s written agreement first,
              not in a release note.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">GDPR roles, stated plainly</h3></div>
            <p className="pub-p">
              The school is the data controller. We are a processor acting on the school’s
              instructions. A <strong>data processing agreement is available</strong> — ask for it
              before you decide anything, along with the current list of subprocessors, and have your
              DPO read both.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">The data stays yours</h3></div>
            <p className="pub-p">
              Marks, students, comments, tags and lessons remain the school’s property throughout. You
              can export all of it in an open format at any point, not just on the way out, and a
              subject access or erasure request is something the system is built to answer rather than
              something we handle by hand.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">One tenant per school</h3></div>
            <p className="pub-p">
              Separation is enforced in the database itself, on every table, alongside a second gate
              that decides which students each person may see at all. A bug in application code cannot
              become a cross-school breach, because the application is not what is holding the line.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">If you leave</h3></div>
            <p className="pub-p">
              You get a full export and a read-only window to run your end-of-year reports, then the
              data is deleted on the schedule in the agreement. No hostage period, and no “contact
              sales to export”.
            </p>
          </div>
          <div className="pub-card">
            <div className="pub-card-head"><h3 className="pub-h3">What we will not claim</h3></div>
            <p className="pub-p">
              We are not going to put a certification badge on this page that we do not hold. Ask us
              what we actually have, what we do not, and who else touches the data. You will get a
              straight list, and you should compare it against what everyone else in this market
              tells you.
            </p>
          </div>
        </div>
      </section>

      <section className="pub-section">
        <h2 className="pub-h2">Talk to us</h2>
        <p className="pub-p">
          The useful first conversation is not a demo. Bring one department’s marks from last term and
          we will show you what the system says about them, including where it says it cannot tell —
          which is the part worth judging us on.
        </p>
        <div className="pub-actions">
          <Link to="/setup" className="pub-btn big">Set up your school</Link>
          <Link to="/method" className="pub-btn ghost big">Read the method first</Link>
        </div>
        <p className="pub-p">
          <span className="pub-placeholder">Placeholder</span>{' '}
          Contact address and quote request form to be added before launch. In the meantime, setting
          your school up starts the same conversation and commits you to nothing.
        </p>
        <p className="pub-p">
          Already have an account? <Link to="/login">Sign in</Link>.
        </p>
      </section>
    </PublicShell>
  )
}
