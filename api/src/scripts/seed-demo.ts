/**
 * Seed a complete, sign-in-able demo school.
 *
 * Run AFTER db/test/synthetic.sql has been loaded. It gives the synthetic staff
 * real credentials, adds a student and a guardian so the portal can be
 * exercised, and prints the logins.
 *
 *   npx tsx src/scripts/seed-demo.ts
 */
import { sql, closeDb } from '../db.js'
import { hashPassword } from '../auth.js'

const PASSWORD = process.env.DEMO_PASSWORD ?? 'demo school passphrase'

async function main() {
  const [tenant] = await sql<{ id: string; name: string }[]>`
    SELECT id, name FROM platform.tenant WHERE slug = 'synthetic-school'`
  if (!tenant) {
    console.error('No synthetic school found. Load db/test/synthetic.sql first.')
    process.exit(1)
  }

  const hash = await hashPassword(PASSWORD)
  const created: { who: string; email: string; roles: string }[] = []

  // 1. Credentials + email for the three staff the synthetic data already made.
  const staff = await sql<{ id: string; display_name: string }[]>`
    SELECT id, display_name FROM platform.app_user WHERE tenant_id = ${tenant.id}`
  for (const u of staff) {
    const email = u.display_name.toLowerCase().replace(/[^a-z]+/g, '.') + '@demo.school'
    await sql`UPDATE platform.app_user SET email = ${email} WHERE id = ${u.id}`
    await sql`INSERT INTO platform.credential (user_id, password_hash) VALUES (${u.id}, ${hash})
              ON CONFLICT (user_id) DO UPDATE SET password_hash = EXCLUDED.password_hash`
    const roles = await sql<{ role: string }[]>`
      SELECT role FROM platform.user_role WHERE user_id = ${u.id}`
    created.push({ who: u.display_name, email, roles: roles.map((r) => r.role).join(', ') })
  }

  // 2. Give one student a login, so the portal has somebody to be.
  const [student] = await sql<{ id: string; given_name: string; family_name: string }[]>`
    SELECT id, given_name, family_name FROM org.person
    WHERE tenant_id = ${tenant.id} AND is_student AND external_ref = 'STU-A1'`
  if (student) {
    const email = 'student@demo.school'
    const [u] = await sql<{ id: string }[]>`
      INSERT INTO platform.app_user (tenant_id, email, display_name)
      VALUES (${tenant.id}, ${email}, ${student.given_name + ' ' + student.family_name})
      RETURNING id`
    await sql`INSERT INTO platform.user_role (tenant_id, user_id, role)
              VALUES (${tenant.id}, ${u!.id}, 'student')`
    await sql`INSERT INTO platform.credential (user_id, password_hash) VALUES (${u!.id}, ${hash})`
    await sql`UPDATE org.person SET user_id = ${u!.id} WHERE id = ${student.id}`
    created.push({ who: `${student.given_name} ${student.family_name} (student)`, email, roles: 'student' })

    // 3. And a guardian linked to that student.
    const gEmail = 'parent@demo.school'
    const [gu] = await sql<{ id: string }[]>`
      INSERT INTO platform.app_user (tenant_id, email, display_name)
      VALUES (${tenant.id}, ${gEmail}, 'Demo Guardian') RETURNING id`
    await sql`INSERT INTO platform.user_role (tenant_id, user_id, role)
              VALUES (${tenant.id}, ${gu!.id}, 'guardian')`
    await sql`INSERT INTO platform.credential (user_id, password_hash) VALUES (${gu!.id}, ${hash})`
    const [gp] = await sql<{ id: string }[]>`
      INSERT INTO org.person (tenant_id, given_name, family_name, user_id)
      VALUES (${tenant.id}, 'Demo', 'Guardian', ${gu!.id}) RETURNING id`
    await sql`INSERT INTO org.guardian_link (tenant_id, student_id, guardian_id, relation)
              VALUES (${tenant.id}, ${student.id}, ${gp!.id}, 'parent')
              ON CONFLICT DO NOTHING`
    created.push({ who: 'Demo Guardian', email: gEmail, roles: 'guardian' })
  }

  // 4. A comment bank, so the reporting screens are not empty on first look.
  const [subject] = await sql<{ id: string }[]>`
    SELECT id FROM org.subject WHERE tenant_id = ${tenant.id} LIMIT 1`
  const bank: [string, string][] = [
    ['excellent', '{first_name} has worked with real independence this term. {they} consistently applies {their} knowledge to unfamiliar problems.'],
    ['secure', '{first_name} has made steady progress. {they} is secure on most of the material and should now push into harder applications.'],
    ['developing', '{first_name} is developing well but would benefit from more practice on {topic}. Short, frequent revision will help more than long sessions.'],
    ['concern', 'I am concerned about {first_name} progress on {topic}. I would like to arrange time to discuss how we can support {them}.'],
  ]
  for (const [band, body] of bank) {
    await sql`INSERT INTO teach.comment_bank (tenant_id, subject_id, band, body, is_shared)
              VALUES (${tenant.id}, ${subject?.id ?? null}, ${band}, ${body}, true)`
  }

  console.log(`\n  Demo school: ${tenant.name}`)
  console.log(`  Password for every account below: ${PASSWORD}\n`)
  for (const c of created) {
    console.log(`    ${c.email.padEnd(32)} ${c.who}  [${c.roles}]`)
  }
  console.log()
  await closeDb()
}

main().catch(async (e) => { console.error(e); await closeDb(); process.exit(1) })
