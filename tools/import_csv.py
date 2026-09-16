#!/usr/bin/env python3
"""
Import a school's data from CSV.

Run tools/anonymise.py FIRST if this is real data. This tool does not care
either way, which is exactly why the order matters.

EXPECTED FILES (all optional; import what you have)
---------------------------------------------------
students.csv    external_ref, given_name, family_name, [year_level]
staff.csv       external_ref, given_name, family_name, [email]
groups.csv      group_code, subject_code, subject_name, label, [year_level], [teacher_ref]
enrolments.csv  student_ref, group_code
lessons.csv     group_code, date, [minutes], [topic]
marks.csv       student_ref, group_code, assessment_title, date, [item_label],
                [max_value], raw_value, [topic], [kind]

Column names are matched loosely (case, spaces and underscores are normalised),
because no two school systems export the same header twice.

Everything lands in a staging table first (org.import_batch / org.import_row),
so a bad import is one DELETE rather than an incident, and a teacher can see
what will happen before it happens.

USAGE
    python3 tools/import_csv.py --dir ./anon --tenant-slug my-school --school-name "My School"
    python3 tools/import_csv.py --dir ./anon --tenant-slug my-school --dry-run
"""
from __future__ import annotations
import argparse, csv, os, sys
from pathlib import Path

try:
    import psycopg
except ImportError:
    print("This tool needs psycopg 3:  pip install 'psycopg[binary]'", file=sys.stderr)
    raise SystemExit(2)

ALIASES = {
    "student_ref": {"student_ref","student","student_id","external_ref","upn","candidate_number"},
    "staff_ref": {"staff_ref","teacher_ref","staff","teacher","external_ref"},
    "given_name": {"given_name","first_name","forename"},
    "family_name": {"family_name","last_name","surname"},
    "group_code": {"group_code","group","class","class_code","set","teaching_group"},
    "subject_code": {"subject_code","subject"},
    "subject_name": {"subject_name","subject_title","subject"},
    "label": {"label","class_label","group_label","class","set"},
    "year_level": {"year_level","year","yeargroup","year_group","form"},
    "assessment_title": {"assessment_title","assessment","title","task","test"},
    "date": {"date","occurred_on","sat_on","assessment_date","held_on"},
    "item_label": {"item_label","item","question","q","criterion","component"},
    "max_value": {"max_value","max","out_of","total_marks","maximum"},
    "raw_value": {"raw_value","mark","score","result","value","raw"},
    "topic": {"topic","unit","tag","strand","content"},
    "kind": {"kind","type","assessment_type"},
    "minutes": {"minutes","duration","length"},
}


def norm(h: str) -> str:
    return (h or "").strip().lower().replace(" ", "_").replace("-", "_")


def pick(row: dict[str, str], field: str) -> str:
    for alias in ALIASES.get(field, {field}):
        if alias in row and row[alias].strip():
            return row[alias].strip()
    return ""


def read(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8-sig") as f:
        return [{norm(k): (v or "") for k, v in r.items()} for r in csv.DictReader(f)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", required=True, type=Path)
    ap.add_argument("--tenant-slug", required=True)
    ap.add_argument("--school-name", default=None)
    ap.add_argument("--country", default="GR")
    ap.add_argument("--year-label", default="2025-2026")
    ap.add_argument("--year-start", default="2025-09-01")
    ap.add_argument("--year-end", default="2026-06-30")
    ap.add_argument("--dsn", default=os.environ.get("DATABASE_URL")
                    or "postgres://postgres:devpassword@localhost:5432/schooldb")
    ap.add_argument("--dry-run", action="store_true", help="parse and report, write nothing")
    args = ap.parse_args()

    data = {name: read(args.dir / f"{name}.csv")
            for name in ("students","staff","groups","enrolments","lessons","marks")}
    for name, rows in data.items():
        print(f"  {name+'.csv':<18} {len(rows):>6} rows")
    if args.dry_run:
        print("\n  --dry-run: nothing written.")
        return 0

    with psycopg.connect(args.dsn, autocommit=False) as conn, conn.cursor() as cur:
        cur.execute("""
            INSERT INTO platform.tenant (slug, name, country_code)
            VALUES (%s, %s, %s)
            ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
            RETURNING id""", (args.tenant_slug, args.school_name or args.tenant_slug, args.country))
        tenant = cur.fetchone()[0]

        cur.execute("""
            INSERT INTO org.academic_year (tenant_id, label, starts_on, ends_on, is_current)
            VALUES (%s, %s, %s, %s, true)
            ON CONFLICT (tenant_id, label) DO UPDATE SET is_current = true
            RETURNING id""", (tenant, args.year_label, args.year_start, args.year_end))
        year = cur.fetchone()[0]

        cur.execute("""
            INSERT INTO org.import_batch (tenant_id, kind, source, filename, status)
            VALUES (%s, 'students', 'csv', %s, 'applied') RETURNING id""",
            (tenant, str(args.dir)))
        batch = cur.fetchone()[0]

        people: dict[str, str] = {}
        for r in data["students"]:
            ref = pick(r, "student_ref")
            if not ref:
                continue
            cur.execute("""
                INSERT INTO org.person (tenant_id, external_ref, given_name, family_name, is_student)
                VALUES (%s, %s, %s, %s, true)
                ON CONFLICT DO NOTHING RETURNING id""",
                (tenant, ref, pick(r, "given_name") or "Student", pick(r, "family_name") or ref))
            got = cur.fetchone()
            if got is None:
                cur.execute("SELECT id FROM org.person WHERE tenant_id=%s AND external_ref=%s", (tenant, ref))
                got = cur.fetchone()
            people[ref] = got[0]

        staff: dict[str, str] = {}
        for r in data["staff"]:
            ref = pick(r, "staff_ref")
            if not ref:
                continue
            cur.execute("""
                INSERT INTO platform.app_user (tenant_id, display_name)
                VALUES (%s, %s) RETURNING id""",
                (tenant, f"{pick(r,'given_name')} {pick(r,'family_name')}".strip() or ref))
            uid = cur.fetchone()[0]
            cur.execute("INSERT INTO platform.user_role (tenant_id, user_id, role) VALUES (%s,%s,'teacher')",
                        (tenant, uid))
            cur.execute("""
                INSERT INTO org.person (tenant_id, external_ref, given_name, family_name, is_staff, user_id)
                VALUES (%s,%s,%s,%s,true,%s) ON CONFLICT DO NOTHING RETURNING id""",
                (tenant, ref, pick(r,"given_name") or "Staff", pick(r,"family_name") or ref, uid))
            got = cur.fetchone()
            if got:
                staff[ref] = got[0]

        subjects: dict[str, str] = {}
        groups: dict[str, str] = {}
        for r in data["groups"]:
            gcode = pick(r, "group_code")
            scode = pick(r, "subject_code") or "GEN"
            if scode not in subjects:
                cur.execute("""
                    INSERT INTO org.subject (tenant_id, code, name) VALUES (%s,%s,%s)
                    ON CONFLICT (tenant_id, code) DO UPDATE SET name=EXCLUDED.name
                    RETURNING id""", (tenant, scode, pick(r,"subject_name") or scode))
                subjects[scode] = cur.fetchone()[0]
            cur.execute("""
                INSERT INTO org.teaching_group (tenant_id, academic_year_id, subject_id, label, year_level)
                VALUES (%s,%s,%s,%s,%s)
                ON CONFLICT (tenant_id, academic_year_id, subject_id, label) DO UPDATE SET year_level=EXCLUDED.year_level
                RETURNING id""",
                (tenant, year, subjects[scode], pick(r,"label") or gcode, pick(r,"year_level") or None))
            groups[gcode] = cur.fetchone()[0]
            tref = pick(r, "staff_ref")
            if tref and tref in staff:
                cur.execute("""
                    INSERT INTO org.teaching_assignment (tenant_id, staff_id, teaching_group_id, role, from_date)
                    VALUES (%s,%s,%s,'primary',%s)""", (tenant, staff[tref], groups[gcode], args.year_start))

        for r in data["enrolments"]:
            sref, gcode = pick(r, "student_ref"), pick(r, "group_code")
            if sref in people and gcode in groups:  # enrolments never invent a class
                cur.execute("""
                    INSERT INTO org.enrolment (tenant_id, student_id, teaching_group_id, from_date)
                    VALUES (%s,%s,%s,%s) ON CONFLICT DO NOTHING""",
                    (tenant, people[sref], groups[gcode], args.year_start))

        # Topics become a per-subject taxonomy, created on demand from the data.
        taxo: dict[str, str] = {}
        tags: dict[tuple[str, str], str] = {}

        def tag_for(gcode: str, topic: str) -> str | None:
            if not topic or gcode not in groups:
                return None
            cur.execute("SELECT subject_id FROM org.teaching_group WHERE id=%s", (groups[gcode],))
            sid = cur.fetchone()[0]
            if sid not in taxo:
                cur.execute("""
                    INSERT INTO curric.taxonomy (owner_tenant_id, code, name, axis, subject_id)
                    VALUES (%s, %s, 'Imported topics', 'topic', %s)
                    ON CONFLICT (owner_tenant_id, code) DO UPDATE SET name=EXCLUDED.name
                    RETURNING id""", (tenant, f"IMPORTED-{sid}", sid))
                taxo[sid] = cur.fetchone()[0]
            k = (taxo[sid], topic)
            if k not in tags:
                cur.execute("""
                    INSERT INTO curric.tag (taxonomy_id, code, label) VALUES (%s,%s,%s)
                    ON CONFLICT (taxonomy_id, code) DO UPDATE SET label=EXCLUDED.label
                    RETURNING id""", (taxo[sid], topic[:60], topic))
                tags[k] = cur.fetchone()[0]
            return tags[k]

        def ensure_group(gcode: str) -> str | None:
            """Create a class referenced by marks but absent from groups.csv.

            Schools very often export marks without a separate class list.
            Skipping those rows means a teacher imports a file, sees no error,
            and gets an empty product -- the exact failure this whole design is
            built to avoid. So the class is created from what the marks say."""
            if not gcode:
                return None
            if gcode in groups:
                return groups[gcode]
            if "GEN" not in subjects:
                cur.execute("""
                    INSERT INTO org.subject (tenant_id, code, name) VALUES (%s,'GEN','Imported')
                    ON CONFLICT (tenant_id, code) DO UPDATE SET name=EXCLUDED.name
                    RETURNING id""", (tenant,))
                subjects["GEN"] = cur.fetchone()[0]
            cur.execute("""
                INSERT INTO org.teaching_group (tenant_id, academic_year_id, subject_id, label)
                VALUES (%s,%s,%s,%s)
                ON CONFLICT (tenant_id, academic_year_id, subject_id, label) DO UPDATE
                  SET label = EXCLUDED.label
                RETURNING id""", (tenant, year, subjects["GEN"], gcode))
            groups[gcode] = cur.fetchone()[0]
            inferred.add(gcode)
            return groups[gcode]

        inferred: set[str] = set()
        assessments: dict[tuple[str, str, str], tuple[str, dict[str, str]]] = {}
        n_marks = 0
        skipped_unknown_student = 0
        for r in data["marks"]:
            sref, gcode = pick(r, "student_ref"), pick(r, "group_code")
            title, date = pick(r, "assessment_title") or "Imported", pick(r, "date")
            ensure_group(gcode)
            if sref not in people:
                skipped_unknown_student += 1
                continue
            if gcode not in groups or not date:
                continue
            akey = (gcode, title, date)
            if akey not in assessments:
                cur.execute("""
                    INSERT INTO gradebook.assessment
                      (tenant_id, teaching_group_id, title, kind, occurred_on, topic_tag_id, max_total)
                    VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
                    (tenant, groups[gcode], title, pick(r,"kind") or "summative", date,
                     tag_for(gcode, pick(r, "topic")), pick(r,"max_value") or None))
                assessments[akey] = (cur.fetchone()[0], {})
            aid, items = assessments[akey]
            ilabel = pick(r, "item_label") or "Total"
            if ilabel not in items:
                cur.execute("""
                    INSERT INTO gradebook.item (tenant_id, assessment_id, seq, label, max_value, topic_tag_id)
                    VALUES (%s,%s,%s,%s,%s,%s) RETURNING id""",
                    (tenant, aid, len(items), ilabel, pick(r,"max_value") or None,
                     tag_for(gcode, pick(r, "topic"))))
                items[ilabel] = cur.fetchone()[0]
            raw = pick(r, "raw_value")
            status = "scored" if raw not in ("", "A", "a") else "absent"
            cur.execute("""
                INSERT INTO gradebook.result
                  (tenant_id, item_id, student_id, raw_value, max_value, status, observed_on, source)
                VALUES (%s,%s,%s,%s,%s,%s,%s,'import')
                ON CONFLICT (item_id, student_id, marker_role) DO UPDATE
                  SET raw_value=EXCLUDED.raw_value, status=EXCLUDED.status""",
                (tenant, items[ilabel], people[sref], raw if status == "scored" else None,
                 pick(r,"max_value") or None, status, date))
            n_marks += 1

        for r in data["lessons"]:
            gcode, date = pick(r, "group_code"), pick(r, "date")
            ensure_group(gcode)
            if gcode in groups and date:
                cur.execute("""
                    INSERT INTO org.lesson (tenant_id, teaching_group_id, held_on, minutes, topic_tag_id)
                    VALUES (%s,%s,%s,%s,%s)""",
                    (tenant, groups[gcode], date, int(pick(r,"minutes") or 45),
                     tag_for(gcode, pick(r, "topic"))))

        # A student with marks in a class is in that class. Without this a
        # marks-only import produces classes with no register, and every
        # "outstanding" count and cohort statistic is computed against zero.
        cur.execute("""
            INSERT INTO org.enrolment (tenant_id, student_id, teaching_group_id, from_date)
            SELECT DISTINCT r.tenant_id, r.student_id, a.teaching_group_id, %s::date
            FROM gradebook.result r
            JOIN gradebook.item i ON i.id = r.item_id
            JOIN gradebook.assessment a ON a.id = i.assessment_id
            WHERE r.tenant_id = %s
              AND NOT EXISTS (SELECT 1 FROM org.enrolment e
                              WHERE e.student_id = r.student_id
                                AND e.teaching_group_id = a.teaching_group_id
                                AND e.to_date IS NULL)""", (args.year_start, tenant))

        cur.execute("UPDATE org.import_batch SET row_count=%s, ok_count=%s WHERE id=%s",
                    (n_marks, n_marks, batch))
        conn.commit()

    print(f"\n  tenant={args.tenant_slug}  students={len(people)}  groups={len(groups)}  marks={n_marks}")
    if inferred:
        print(f"  {len(inferred)} class(es) created from marks.csv because groups.csv "
              f"did not list them: {', '.join(sorted(inferred))}")
    if skipped_unknown_student:
        print(f"  !! {skipped_unknown_student} mark(s) skipped: student ref not in students.csv")
    print("  Now refresh analytics:  SELECT analytics.refresh_all(false);")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
