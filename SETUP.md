# Setting it up

## What you need installed

**Docker Desktop.** That is the whole list. Postgres, Node and everything else
runs inside it.

## Run it

```bash
git clone https://github.com/DimiKamou/Student--School-DB.git
cd Student--School-DB
docker compose up
```

First boot takes a couple of minutes — it creates the database, runs all eleven
migrations, and seeds every grading framework (IB MYP, IB DP, Greek Panhellenic,
AQA, Edexcel, OCR, Cambridge, BTEC).

Then open **http://localhost:5173**.

There are no passwords yet. The sign-in screen lists accounts; pick one. Which
one you pick matters — the database enforces what each person can see, so a
class teacher genuinely cannot load another teacher's students.

## Load the demo school

To see the analytics doing anything, you need data:

```bash
docker compose exec db psql -U postgres -d schooldb -f /dev/stdin < db/test/synthetic.sql
docker compose exec db psql -U postgres -d schooldb -c "SELECT analytics.refresh_all(false);"
```

That is a synthetic year with problems deliberately planted in it: one student
with a real topic gap, one whole class failing a topic that was under-taught,
one student whose work falls off in February. Sign in as **Elena Papadaki** and
they should all be on the first screen.

## Load your school's real data

**Do these in this order. The order is the point.**

### 1. Export to CSV

Whatever your school's system gives you. The importer matches column names
loosely, so `Surname`, `surname` and `family_name` all work. See
`examples/export/` for the shape.

The only file that really matters is `marks.csv` — if a class or an enrolment is
missing, the importer infers it from the marks rather than silently dropping
them.

### 2. Anonymise — before the data goes anywhere

```bash
python3 tools/anonymise.py --in ./export --out ./anon
```

This strips names, emails, SEN flags and free-text comments, reduces dates of
birth to the year, and replaces every id with a pseudonym that stays consistent
across files so the data still joins.

Then it **destroys the mapping**. That is the difference between *pseudonymised*
data, which is still personal data in full GDPR scope, and *anonymised* data,
which is out of scope entirely.

You can pass `--keep-mapping` to retain it. Only do that if you have a concrete
reason to re-identify someone, because it puts you back in scope — and the tool
will say so.

You lose nothing analytically. Not one signal in this platform needs a real name.

### 3. Import

```bash
pip install 'psycopg[binary]'
python3 tools/import_csv.py --dir ./anon --tenant-slug ims --school-name "International Metropolitan School"
docker compose exec db psql -U postgres -d schooldb -c "SELECT analytics.refresh_all(false);"
```

Add `--dry-run` first to see what it parsed without writing anything.

### 4. A caution about small classes

Anonymising names does not make a class of six anonymous. "The only student
taking Further Maths and Music" is identifiable to any colleague, whatever name
is on the row. Treat small-group output as personal data regardless.

## Running the tests

```bash
./db/test/run_tests.sh
```

Builds a synthetic year with known planted signals and scores the engine on
finding them *and* staying quiet where nothing was planted. All nine assertions
must pass.

## Without Docker

You need PostgreSQL 16, Node 22 and Python 3.11:

```bash
createdb schooldb && ./db/rebuild.sh
cd api && npm install && npm run dev      # :3001
cd web && npm install && npm run dev      # :5173
```

## Before any other school uses this

Not needed while it runs on your laptop. Needed the day someone else's students
are in it:

| | |
|---|---|
| **Real authentication** | `dev-login` refuses to run outside development, so there is currently no way in. Magic link or school SSO. |
| **EU hosting** | Supabase or Neon, EU region. Minors' data does not leave the EU. |
| **`SESSION_SECRET`** | The default is a literal placeholder. |
| **A DPA** | The school is the data controller, you are the processor. No school DPO signs without one. |
| **Backups you have restored** | An untested backup is not a backup. |
| **Scheduled refresh** | `analytics.refresh_all(true)` nightly. Concurrent, so it never blocks readers. |
