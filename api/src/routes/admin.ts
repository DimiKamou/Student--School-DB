import type { FastifyInstance } from 'fastify'
import type postgres from 'postgres'
import { z } from 'zod'
import { asOwner, withTenant } from '../db.js'
import { HttpError, requireRole } from '../auth.js'

/**
 * SCHOOL ADMINISTRATION
 *
 * Every handler in this file calls requireRole(req, 'school_admin') as its
 * first statement. Hiding the nav link is presentation; this is the control.
 *
 * Every tenant-data query runs inside withTenant(), so RLS and the SET LOCAL
 * tenant context do the isolating rather than a WHERE clause somebody may
 * forget. Two exceptions are marked and explained where they occur:
 *
 *   1. platform.tenant carries no tenant_id column, so the generated RLS loop
 *      in 009_rls.sql neither enabled a policy on it nor granted it to app_rw.
 *      Reading or writing a school's own governance settings therefore has to
 *      go through asOwner(), and every such statement filters on
 *      `id = session.tenantId` by hand. That id comes from the signed session
 *      cookie, never from the request body.
 *
 *   2. curric.tag and curric.tag_closure have neither tenant_id nor
 *      owner_tenant_id: they hang off curric.taxonomy, which has the
 *      owner_tenant_id policy. So every tag write here is constrained by a
 *      subquery on curric.taxonomy WHERE owner_tenant_id = the current tenant,
 *      which also stops a school editing the platform-published (global)
 *      taxonomies it can read.
 */

const uuid = z.string().uuid()
const idParam = z.object({ id: uuid })

export async function registerAdminRoutes(app: FastifyInstance) {
  // =========================================================================
  // PEOPLE
  // =========================================================================

  /**
   * Staff as PEOPLE rather than as login accounts.
   *
   * /users (auth.ts) lists platform.app_user — who can sign in. Assignments
   * hang off org.person, and the two are not the same set: a teacher imported
   * from the MIS exists as a person with no account, and an account created by
   * an invite gets a person row attached at accept time. The directory has to
   * show both or a school ends up with duplicate teachers.
   */
  app.get('/admin/staff', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT p.id, p.given_name, p.family_name, p.preferred_name, p.external_ref,
             p.user_id, p.left_on,
             u.display_name, u.email::text AS email, u.is_active, u.last_seen_at,
             coalesce(
               (SELECT array_agg(ur.role ORDER BY ur.role)
                  FROM platform.user_role ur
                 WHERE ur.tenant_id = p.tenant_id AND ur.user_id = p.user_id),
               '{}') AS roles,
             (SELECT count(*) FROM org.teaching_assignment ta
               WHERE ta.staff_id = p.id AND ta.to_date IS NULL) AS n_classes,
             (SELECT count(*) FROM org.tutor_assignment tu
               WHERE tu.staff_id = p.id AND tu.to_date IS NULL) AS n_tutees
      FROM org.person p
      LEFT JOIN platform.app_user u ON u.id = p.user_id
      WHERE p.is_staff AND p.deleted_at IS NULL
      ORDER BY p.family_name, p.given_name`)
  })

  /**
   * Every class in the school for the current year, with who teaches it.
   *
   * /groups in teaching.ts answers "my classes"; an administrator assigning
   * cover needs the ones that are nobody's. The unstaffed count is the point
   * of the screen: a class with no current teaching_assignment produces no
   * alert owner in analytics.fire_alerts(), so its findings go to nobody.
   */
  app.get('/admin/groups', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT tg.id, tg.label, tg.year_level, tg.level_code,
             tg.subject_id, sub.name AS subject_name, sub.code AS subject_code,
             tg.academic_year_id, ay.label AS academic_year, ay.is_current,
             tg.framework_version_id,
             fv.label AS framework_version_label,
             fw.name  AS framework_name,
             (SELECT count(*) FROM org.enrolment e
               WHERE e.teaching_group_id = tg.id AND e.to_date IS NULL) AS n_students,
             coalesce(
               (SELECT array_agg(p.family_name || ', ' || p.given_name
                                 ORDER BY p.family_name, p.given_name)
                  FROM org.teaching_assignment ta
                  JOIN org.person p ON p.id = ta.staff_id
                 WHERE ta.teaching_group_id = tg.id AND ta.to_date IS NULL),
               '{}') AS teachers
      FROM org.teaching_group tg
      JOIN org.subject sub ON sub.id = tg.subject_id
      JOIN org.academic_year ay ON ay.id = tg.academic_year_id
      LEFT JOIN ref.framework_version fv ON fv.id = tg.framework_version_id
      LEFT JOIN ref.framework fw ON fw.id = fv.framework_id
      WHERE ay.is_current
      ORDER BY sub.name, tg.label`)
  })

  /** Current teaching assignments, one row each, so one can be ended. */
  app.get('/admin/teaching-assignments', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT ta.id, ta.role, ta.from_date, ta.to_date,
             ta.staff_id, p.given_name, p.family_name,
             ta.teaching_group_id, tg.label AS group_label, sub.name AS subject_name
      FROM org.teaching_assignment ta
      JOIN org.person p ON p.id = ta.staff_id
      JOIN org.teaching_group tg ON tg.id = ta.teaching_group_id
      JOIN org.subject sub ON sub.id = tg.subject_id
      JOIN org.academic_year ay ON ay.id = tg.academic_year_id
      WHERE ta.to_date IS NULL AND ay.is_current
      ORDER BY p.family_name, sub.name, tg.label`)
  })

  app.post('/admin/teaching-assignments', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({
      staff_id: uuid,
      teaching_group_id: uuid,
      role: z.enum(['primary', 'co_teacher', 'support', 'cover', 'moderator']).default('primary'),
    }).parse(req.body)

    return withTenant(s, async (tx) => {
      // Already assigned and still current: silently duplicating the row would
      // give this teacher two alert-owner candidates for the same class.
      const [dup] = await tx<{ id: string }[]>`
        SELECT id FROM org.teaching_assignment
        WHERE staff_id = ${b.staff_id} AND teaching_group_id = ${b.teaching_group_id}
          AND role = ${b.role} AND to_date IS NULL`
      if (dup) return { ok: true, id: dup.id, already: true }

      const [row] = await tx<{ id: string }[]>`
        INSERT INTO org.teaching_assignment (tenant_id, staff_id, teaching_group_id, role)
        VALUES (${s.tenantId}, ${b.staff_id}, ${b.teaching_group_id}, ${b.role})
        RETURNING id`
      return { ok: true, id: row!.id, already: false }
    })
  })

  /**
   * End an assignment rather than delete it. "The teacher changed in January"
   * is one of the commonest causes of a period effect, and a deleted row makes
   * that unaskable.
   */
  app.post('/admin/teaching-assignments/:id/end', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const rows = await tx`
        UPDATE org.teaching_assignment SET to_date = current_date
        WHERE id = ${id} AND to_date IS NULL RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'no such open assignment')
      return { ok: true }
    })
  })

  /** Students, for tutor assignment. Admins are school-wide, so scope passes. */
  app.get('/admin/students', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { q } = z.object({ q: z.string().max(80).optional() }).parse(req.query)
    const like = q && q.trim() ? `%${q.trim()}%` : null
    return withTenant(s, async (tx) => tx`
      SELECT p.id, p.given_name, p.family_name, p.preferred_name, p.external_ref,
             p.is_provisional,
             (SELECT count(*) FROM org.tutor_assignment tu
               WHERE tu.student_id = p.id AND tu.to_date IS NULL) AS n_tutors
      FROM org.person p
      WHERE p.is_student AND p.deleted_at IS NULL
        AND (${like}::text IS NULL
             OR p.given_name ILIKE ${like} OR p.family_name ILIKE ${like}
             OR p.external_ref ILIKE ${like})
      ORDER BY p.family_name, p.given_name
      LIMIT 200`)
  })

  app.get('/admin/tutor-assignments', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT tu.id, tu.from_date, tu.to_date,
             tu.staff_id, st.given_name AS staff_given, st.family_name AS staff_family,
             tu.student_id, sp.given_name AS student_given, sp.family_name AS student_family,
             sp.external_ref
      FROM org.tutor_assignment tu
      JOIN org.person st ON st.id = tu.staff_id
      JOIN org.person sp ON sp.id = tu.student_id
      WHERE tu.to_date IS NULL
      ORDER BY st.family_name, sp.family_name, sp.given_name`)
  })

  app.post('/admin/tutor-assignments', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({ staff_id: uuid, student_id: uuid }).parse(req.body)
    return withTenant(s, async (tx) => {
      const [dup] = await tx<{ id: string }[]>`
        SELECT id FROM org.tutor_assignment
        WHERE staff_id = ${b.staff_id} AND student_id = ${b.student_id} AND to_date IS NULL`
      if (dup) return { ok: true, id: dup.id, already: true }
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO org.tutor_assignment (tenant_id, staff_id, student_id)
        VALUES (${s.tenantId}, ${b.staff_id}, ${b.student_id})
        RETURNING id`
      return { ok: true, id: row!.id, already: false }
    })
  })

  app.post('/admin/tutor-assignments/:id/end', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const rows = await tx`
        UPDATE org.tutor_assignment SET to_date = current_date
        WHERE id = ${id} AND to_date IS NULL RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'no such open assignment')
      return { ok: true }
    })
  })

  // =========================================================================
  // SCHOOL — calendar, structure, governance
  // =========================================================================

  /**
   * Everything the School screen needs in one round trip.
   *
   * The tenant row is read through asOwner() for the reason documented at the
   * top of this file, with an explicit id filter taken from the session.
   */
  app.get('/admin/school', async (req) => {
    const s = requireRole(req, 'school_admin')

    const [tenant] = await asOwner(async (tx) => tx<{
      id: string; name: string; slug: string; country_code: string; timezone: string
      plan: string; subscription_ends_on: string | null
      alert_budget_weekly: number; leadership_delay_days: number
      data_retention_years: number
    }[]>`
      SELECT id, name, slug, country_code, timezone, plan, subscription_ends_on,
             alert_budget_weekly, leadership_delay_days, data_retention_years
      FROM platform.tenant WHERE id = ${s.tenantId}`)
    if (!tenant) throw new HttpError(404, 'school not found')

    return withTenant(s, async (tx) => {
      const [years, terms, departments, subjects] = await Promise.all([
        tx`SELECT ay.id, ay.label, ay.starts_on, ay.ends_on, ay.is_current,
                  (SELECT count(*) FROM org.term t WHERE t.academic_year_id = ay.id) AS n_terms,
                  (SELECT count(*) FROM org.teaching_group tg
                    WHERE tg.academic_year_id = ay.id) AS n_groups
           FROM org.academic_year ay ORDER BY ay.starts_on DESC`,
        tx`SELECT t.id, t.academic_year_id, t.label, t.seq, t.starts_on, t.ends_on,
                  t.is_reporting
           FROM org.term t ORDER BY t.starts_on`,
        tx`SELECT d.id, d.name,
                  (SELECT count(*) FROM org.subject sub WHERE sub.department_id = d.id) AS n_subjects
           FROM org.department d ORDER BY d.name`,
        tx`SELECT sub.id, sub.code, sub.name, sub.department_id, d.name AS department_name,
                  (SELECT count(*) FROM org.teaching_group tg
                    WHERE tg.subject_id = sub.id) AS n_groups
           FROM org.subject sub
           LEFT JOIN org.department d ON d.id = sub.department_id
           ORDER BY sub.name`,
      ])
      return { tenant, years, terms, departments, subjects }
    })
  })

  /**
   * Alert budget and leadership delay.
   *
   * Both are governance, not preferences. The budget is the cap in
   * analytics.fire_alerts(): a teacher gets their N largest findings per run
   * and nothing else, which is what stops the product training people to
   * dismiss it. The delay is the teacher's right of first sight — a systemic
   * flag about their class is theirs for this many days before leadership can
   * see it. Setting it to 0 turns the product into surveillance, so the UI
   * says so rather than quietly accepting it.
   */
  app.post('/admin/school/settings', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({
      alert_budget_weekly: z.coerce.number().int().min(0).max(50),
      leadership_delay_days: z.coerce.number().int().min(0).max(90),
    }).parse(req.body)

    const [row] = await asOwner(async (tx) => tx<{
      alert_budget_weekly: number; leadership_delay_days: number
    }[]>`
      UPDATE platform.tenant
      SET alert_budget_weekly = ${b.alert_budget_weekly},
          leadership_delay_days = ${b.leadership_delay_days}
      WHERE id = ${s.tenantId}
      RETURNING alert_budget_weekly, leadership_delay_days`)
    if (!row) throw new HttpError(404, 'school not found')
    return { ok: true, ...row }
  })

  app.post('/admin/academic-years', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({
      label: z.string().min(2).max(40),
      starts_on: z.string().date(),
      ends_on: z.string().date(),
      is_current: z.boolean().default(false),
    }).parse(req.body)
    if (b.ends_on <= b.starts_on) throw new HttpError(400, 'The year must end after it starts.')

    return withTenant(s, async (tx) => {
      // One current year per tenant is a unique partial index; clear first.
      if (b.is_current) {
        await tx`UPDATE org.academic_year SET is_current = false WHERE is_current`
      }
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO org.academic_year (tenant_id, label, starts_on, ends_on, is_current)
        VALUES (${s.tenantId}, ${b.label}, ${b.starts_on}, ${b.ends_on}, ${b.is_current})
        RETURNING id`
      return { ok: true, id: row!.id }
    })
  })

  app.post('/admin/academic-years/:id/current', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    return withTenant(s, async (tx) => {
      await tx`UPDATE org.academic_year SET is_current = false WHERE is_current`
      const rows = await tx`
        UPDATE org.academic_year SET is_current = true WHERE id = ${id} RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'no such academic year')
      return { ok: true }
    })
  })

  /**
   * Terms are the reporting periods every period-level analytic is keyed by:
   * mv_student_period_effect and mv_cohort_period_effect group on the term a
   * mark falls in, by date. A year with no terms produces no period analysis
   * at all, and terms that leave gaps silently drop the marks in the gap.
   */
  app.post('/admin/terms', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({
      academic_year_id: uuid,
      label: z.string().min(1).max(40),
      seq: z.coerce.number().int().min(1).max(12),
      starts_on: z.string().date(),
      ends_on: z.string().date(),
      is_reporting: z.boolean().default(true),
    }).parse(req.body)
    if (b.ends_on <= b.starts_on) throw new HttpError(400, 'The term must end after it starts.')

    return withTenant(s, async (tx) => {
      const [dup] = await tx<{ id: string }[]>`
        SELECT id FROM org.term
        WHERE academic_year_id = ${b.academic_year_id} AND seq = ${b.seq}`
      if (dup) throw new HttpError(409, `That year already has a term ${b.seq}.`)
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO org.term (tenant_id, academic_year_id, label, seq, starts_on, ends_on,
                              is_reporting)
        VALUES (${s.tenantId}, ${b.academic_year_id}, ${b.label}, ${b.seq},
                ${b.starts_on}, ${b.ends_on}, ${b.is_reporting})
        RETURNING id`
      return { ok: true, id: row!.id }
    })
  })

  app.post('/admin/terms/:id/delete', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const rows = await tx`DELETE FROM org.term WHERE id = ${id} RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'no such term')
      return { ok: true }
    })
  })

  app.post('/admin/departments', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({ name: z.string().min(1).max(80) }).parse(req.body)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO org.department (tenant_id, name) VALUES (${s.tenantId}, ${b.name})
        ON CONFLICT (tenant_id, name) DO UPDATE SET name = EXCLUDED.name
        RETURNING id`
      return { ok: true, id: row!.id }
    })
  })

  app.post('/admin/subjects', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({
      code: z.string().min(1).max(24),
      name: z.string().min(1).max(80),
      department_id: uuid.nullish(),
    }).parse(req.body)
    return withTenant(s, async (tx) => {
      const [dup] = await tx<{ id: string }[]>`
        SELECT id FROM org.subject WHERE code = ${b.code}`
      if (dup) throw new HttpError(409, `A subject with code ${b.code} already exists.`)
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO org.subject (tenant_id, department_id, code, name)
        VALUES (${s.tenantId}, ${b.department_id ?? null}, ${b.code}, ${b.name})
        RETURNING id`
      return { ok: true, id: row!.id }
    })
  })

  app.post('/admin/subjects/:id/update', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    const b = z.object({
      name: z.string().min(1).max(80),
      department_id: uuid.nullish(),
    }).parse(req.body)
    return withTenant(s, async (tx) => {
      const rows = await tx`
        UPDATE org.subject SET name = ${b.name}, department_id = ${b.department_id ?? null}
        WHERE id = ${id} RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'no such subject')
      return { ok: true }
    })
  })

  // =========================================================================
  // CURRICULUM — taxonomies, tags, framework binding
  // =========================================================================

  /**
   * Taxonomies this school can see: its own, which it may edit, and the
   * platform-published ones (IB guides, ΙΕΠ ύλη), which it may not. RLS on
   * curric.taxonomy returns both; `is_editable` is what the UI needs to know
   * about the difference, and every write below re-checks it server-side.
   */
  app.get('/admin/taxonomies', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT tx2.id, tx2.code, tx2.name, tx2.axis, tx2.source_ref,
             tx2.subject_id, sub.name AS subject_name,
             (tx2.owner_tenant_id = ${s.tenantId}) AS is_editable,
             (SELECT count(*) FROM curric.tag t WHERE t.taxonomy_id = tx2.id) AS n_tags,
             (SELECT count(*) FROM curric.tag t
               WHERE t.taxonomy_id = tx2.id AND t.nominal_minutes IS NOT NULL)
               AS n_tags_with_time
      FROM curric.taxonomy tx2
      LEFT JOIN org.subject sub ON sub.id = tx2.subject_id
      ORDER BY (tx2.owner_tenant_id = ${s.tenantId}) DESC, tx2.axis, tx2.name`)
  })

  app.post('/admin/taxonomies', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({
      code: z.string().min(1).max(40),
      name: z.string().min(1).max(120),
      axis: z.enum(['topic', 'skill', 'content_type', 'command_term', 'cognitive_level',
        'global_context', 'key_concept', 'atl']),
      subject_id: uuid.nullish(),
      source_ref: z.string().max(200).nullish(),
    }).parse(req.body)

    return withTenant(s, async (tx) => {
      // owner_tenant_id defaults to the GLOBAL tenant, which the ref_visibility
      // WITH CHECK would reject. Set it explicitly to this school.
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO curric.taxonomy (owner_tenant_id, code, name, axis, subject_id, source_ref)
        VALUES (${s.tenantId}, ${b.code}, ${b.name}, ${b.axis},
                ${b.subject_id ?? null}, ${b.source_ref ?? null})
        RETURNING id`
      return { ok: true, id: row!.id }
    })
  })

  /**
   * The tag tree for one taxonomy, with the delivered teaching time beside the
   * nominal time. nominal_minutes is what makes under-taught detection possible
   * at all: without it, "this topic got two lessons" has nothing to be two
   * lessons short OF, and mv_cohort_tag can only ever say "taught badly".
   */
  app.get('/admin/taxonomies/:id/tags', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [tax] = await tx<{ id: string; is_editable: boolean }[]>`
        SELECT id, (owner_tenant_id = ${s.tenantId}) AS is_editable
        FROM curric.taxonomy WHERE id = ${id}`
      if (!tax) throw new HttpError(404, 'no such taxonomy')
      const tags = await tx`
        SELECT t.id, t.code, t.label, t.parent_id, t.sort_order, t.is_leaf,
               t.nominal_minutes,
               (SELECT count(*) FROM curric.tag c WHERE c.parent_id = t.id) AS n_children,
               (SELECT coalesce(sum(l.minutes), 0) FROM org.lesson l
                 WHERE l.topic_tag_id = t.id AND NOT l.was_cancelled) AS delivered_minutes,
               (SELECT count(*) FROM curric.tag_closure cl
                 WHERE cl.descendant_id = t.id) - 1 AS depth
        FROM curric.tag t
        WHERE t.taxonomy_id = ${id}
        ORDER BY t.sort_order, t.label`
      return { taxonomy: tax, tags }
    })
  })

  app.post('/admin/tags', async (req) => {
    const s = requireRole(req, 'school_admin')
    const b = z.object({
      taxonomy_id: uuid,
      code: z.string().min(1).max(40),
      label: z.string().min(1).max(160),
      parent_id: uuid.nullish(),
      sort_order: z.coerce.number().int().min(0).max(9999).default(0),
      nominal_minutes: z.coerce.number().int().min(0).max(100000).nullish(),
    }).parse(req.body)

    return withTenant(s, async (tx) => {
      await assertOwnTaxonomy(tx, s.tenantId, b.taxonomy_id)
      if (b.parent_id) {
        const [p] = await tx<{ id: string }[]>`
          SELECT id FROM curric.tag WHERE id = ${b.parent_id} AND taxonomy_id = ${b.taxonomy_id}`
        if (!p) throw new HttpError(400, 'The parent must be in the same taxonomy.')
      }
      const [dup] = await tx<{ id: string }[]>`
        SELECT id FROM curric.tag WHERE taxonomy_id = ${b.taxonomy_id} AND code = ${b.code}`
      if (dup) throw new HttpError(409, `This taxonomy already has a tag coded ${b.code}.`)

      // curric.tag_closure is maintained by the trigger in 004; inserting the
      // row with its parent_id is all that is required.
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, nominal_minutes)
        VALUES (${b.taxonomy_id}, ${b.parent_id ?? null}, ${b.code}, ${b.label},
                ${b.sort_order}, ${b.nominal_minutes ?? null})
        RETURNING id`
      return { ok: true, id: row!.id }
    })
  })

  app.post('/admin/tags/:id/update', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    const b = z.object({
      label: z.string().min(1).max(160),
      parent_id: uuid.nullish(),
      sort_order: z.coerce.number().int().min(0).max(9999).default(0),
      nominal_minutes: z.coerce.number().int().min(0).max(100000).nullish(),
    }).parse(req.body)

    return withTenant(s, async (tx) => {
      const [tag] = await tx<{ id: string; taxonomy_id: string }[]>`
        SELECT id, taxonomy_id FROM curric.tag WHERE id = ${id}`
      if (!tag) throw new HttpError(404, 'no such tag')
      await assertOwnTaxonomy(tx, s.tenantId, tag.taxonomy_id)

      if (b.parent_id) {
        if (b.parent_id === id) throw new HttpError(400, 'A tag cannot be its own parent.')
        const [p] = await tx<{ id: string }[]>`
          SELECT id FROM curric.tag WHERE id = ${b.parent_id} AND taxonomy_id = ${tag.taxonomy_id}`
        if (!p) throw new HttpError(400, 'The parent must be in the same taxonomy.')
        // Re-parenting a tag under its own descendant would make a cycle, and
        // the closure trigger would rebuild it into an infinite subtree.
        const [cycle] = await tx<{ n: number }[]>`
          SELECT 1 AS n FROM curric.tag_closure
          WHERE ancestor_id = ${id} AND descendant_id = ${b.parent_id}`
        if (cycle) throw new HttpError(400, 'That would put a topic underneath itself.')
      }

      await tx`
        UPDATE curric.tag
        SET label = ${b.label}, parent_id = ${b.parent_id ?? null},
            sort_order = ${b.sort_order}, nominal_minutes = ${b.nominal_minutes ?? null}
        WHERE id = ${id}`
      return { ok: true }
    })
  })

  app.post('/admin/tags/:id/delete', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [tag] = await tx<{ id: string; taxonomy_id: string }[]>`
        SELECT id, taxonomy_id FROM curric.tag WHERE id = ${id}`
      if (!tag) throw new HttpError(404, 'no such tag')
      await assertOwnTaxonomy(tx, s.tenantId, tag.taxonomy_id)

      // Deleting a tag cascades to its children and detaches every assessment
      // and lesson tagged with it, which silently destroys the topic analytics
      // already computed from them. Refuse while anything points at it.
      const [used] = await tx<{ n_children: string; n_lessons: string
                                n_assessments: string; n_items: string }[]>`
        SELECT (SELECT count(*) FROM curric.tag c WHERE c.parent_id = ${id}) AS n_children,
               (SELECT count(*) FROM org.lesson l WHERE l.topic_tag_id = ${id}) AS n_lessons,
               (SELECT count(*) FROM gradebook.assessment a WHERE a.topic_tag_id = ${id})
                 AS n_assessments,
               (SELECT count(*) FROM gradebook.item i
                 WHERE i.topic_tag_id = ${id} OR i.skill_tag_id = ${id}) AS n_items`
      if (used && (Number(used.n_children) > 0 || Number(used.n_lessons) > 0 ||
                   Number(used.n_assessments) > 0 || Number(used.n_items) > 0)) {
        throw new HttpError(409,
          `Still in use: ${used.n_children} sub-topics, ${used.n_lessons} lessons, ` +
          `${used.n_assessments} assessments, ${used.n_items} tagged questions. ` +
          'Re-tag those first.')
      }
      await tx`DELETE FROM curric.tag WHERE id = ${id}`
      return { ok: true }
    })
  })

  /**
   * The grading frameworks already seeded, with how many of this school's
   * classes are bound to each version. Binding is OPTIONAL — org.teaching_group
   * .framework_version_id is nullable on purpose — so this list is an offer,
   * not a required setup step.
   */
  app.get('/admin/frameworks', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT fw.id AS framework_id, fw.code, fw.name, fw.country_code, fw.awarding_body,
             (fw.owner_tenant_id = ${s.tenantId}) AS is_school_authored,
             fv.id AS framework_version_id, fv.label AS version_label,
             fv.valid_from, fv.valid_to,
             (SELECT count(*) FROM org.teaching_group tg
               WHERE tg.framework_version_id = fv.id) AS n_groups
      FROM ref.framework fw
      JOIN ref.framework_version fv ON fv.framework_id = fw.id
      ORDER BY fw.name, fv.valid_from DESC`)
  })

  app.post('/admin/groups/:id/framework', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = idParam.parse(req.params)
    const b = z.object({ framework_version_id: uuid.nullable() }).parse(req.body)

    return withTenant(s, async (tx) => {
      if (b.framework_version_id) {
        // FK validation bypasses RLS, so the visibility check has to happen on
        // the read path: joining ref.framework applies the ref_visibility
        // policy and a version owned by another school simply is not there.
        const [ok] = await tx<{ id: string }[]>`
          SELECT fv.id FROM ref.framework_version fv
          JOIN ref.framework fw ON fw.id = fv.framework_id
          WHERE fv.id = ${b.framework_version_id}`
        if (!ok) throw new HttpError(400, 'That grading framework is not available to this school.')
      }
      const rows = await tx`
        UPDATE org.teaching_group SET framework_version_id = ${b.framework_version_id}
        WHERE id = ${id} RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'no such class')
      return { ok: true }
    })
  })
}

/**
 * A school may READ the platform-published taxonomies (that is what makes the
 * IB and ΙΕΠ trees usable) but must never edit them, and curric.tag carries no
 * ownership column of its own to enforce that. So every tag write funnels
 * through here.
 */
async function assertOwnTaxonomy(
  tx: postgres.TransactionSql,
  tenantId: string,
  taxonomyId: string,
): Promise<void> {
  const rows = await tx<{ id: string }[]>`
    SELECT id FROM curric.taxonomy
    WHERE id = ${taxonomyId} AND owner_tenant_id = ${tenantId}`
  if (rows.length === 0) {
    throw new HttpError(403,
      'That taxonomy is published by the platform. Copy it to your school to change it.')
  }
}
