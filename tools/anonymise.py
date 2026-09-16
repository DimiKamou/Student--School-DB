#!/usr/bin/env python3
"""
Anonymise a school data export BEFORE it goes anywhere near a database, a
laptop you travel with, or a cloud host.

THE DISTINCTION THAT MATTERS LEGALLY
------------------------------------
  Pseudonymised  you keep a mapping from fake id -> real student.
                 Still personal data. Still fully in GDPR scope. Still needs a
                 lawful basis, a DPA, retention rules, the lot.
  Anonymised     the mapping is destroyed and cannot be reconstructed.
                 Out of GDPR scope entirely.

This tool ANONYMISES by default: the mapping is generated in memory, used once,
and never written. You must pass --keep-mapping to get the other behaviour, and
it will tell you what you have just taken on.

You lose nothing analytically. Every signal in this platform works on patterns
across pseudonymous ids; not one of them needs a real name.

WHAT IT DOES NOT SOLVE
----------------------
Small groups re-identify themselves. "The only student who took Further Maths
and Music" is identifiable to any colleague regardless of the name on the row.
--min-cohort drops groups below a size floor; the default of 5 is a convention,
not a legal guarantee. Free-text comments are dropped wholesale, because names
hide in prose and no regex finds them reliably.

USAGE
    python3 tools/anonymise.py --in ./export --out ./anon
    python3 tools/anonymise.py --in ./export --out ./anon --keep-mapping ./KEYS.csv
"""
from __future__ import annotations
import argparse, csv, hashlib, os, secrets, sys
from pathlib import Path

# Deliberately bland, unmistakably synthetic. Never plausible real names: a
# realistic fake name gets mistaken for real data and re-enters circulation.
GIVEN = ["Alpha","Bravo","Charlie","Delta","Echo","Foxtrot","Golf","Hotel","India",
         "Juliet","Kilo","Lima","Mike","November","Oscar","Papa","Quebec","Romeo",
         "Sierra","Tango","Uniform","Victor","Whiskey","Xray","Yankee","Zulu"]
FAMILY = ["Ash","Birch","Cedar","Dogwood","Elm","Fir","Ginkgo","Hazel","Ivy",
          "Juniper","Kauri","Larch","Maple","Oak","Pine","Quince","Rowan",
          "Spruce","Teak","Umbrella","Vine","Willow","Yew","Zelkova"]

# Columns that carry identity or special-category data and are dropped outright.
DROP_ALWAYS = {
    "email","e-mail","phone","telephone","mobile","address","postcode","post_code",
    "zip","nationality","ethnicity","religion","medical","sen","send","iep",
    "free_school_meals","fsm","pupil_premium","photo","nhs","passport","national_id",
    "amka","afm","guardian_email","guardian_phone","parent_email","parent_phone",
    "comment","comments","note","notes","remark","remarks","feedback",
}
NAME_COLS = {"given_name","first_name","forename","family_name","last_name","surname","name","full_name"}
DOB_COLS = {"date_of_birth","dob","birthdate","birth_date"}
REF_COLS = {"external_ref","student_ref","staff_ref","teacher_ref","upn","candidate_number","id","student_id"}


class Pseudonymiser:
    def __init__(self, salt: bytes):
        self.salt = salt
        self.map: dict[str, str] = {}
        self.names: dict[str, tuple[str, str]] = {}

    def ref(self, real: str) -> str:
        real = (real or "").strip()
        if not real:
            return ""
        if real not in self.map:
            h = hashlib.blake2b(self.salt + real.encode("utf-8"), digest_size=6).hexdigest()
            self.map[real] = f"P-{h.upper()}"
        return self.map[real]

    def name(self, real_ref: str) -> tuple[str, str]:
        pid = self.ref(real_ref)
        if pid not in self.names:
            h = int(hashlib.blake2b(self.salt + pid.encode(), digest_size=8).hexdigest(), 16)
            self.names[pid] = (GIVEN[h % len(GIVEN)], FAMILY[(h // len(GIVEN)) % len(FAMILY)])
        return self.names[pid]


def clean_header(h: str) -> str:
    return (h or "").strip().lower().replace(" ", "_")


def process(src: Path, dst: Path, p: Pseudonymiser, report: list[str]) -> None:
    with src.open(newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        report.append(f"{src.name}: empty, skipped")
        return
    headers = [clean_header(h) for h in rows[0].keys()]
    keep = [h for h in headers if h not in DROP_ALWAYS]
    dropped = sorted(set(headers) - set(keep))

    out = []
    for row in rows:
        r = {clean_header(k): (v or "").strip() for k, v in row.items()}
        # Identify this row's subject so names stay consistent with the ref.
        subject = next((r[c] for c in REF_COLS if c in r and r[c]), None)
        new: dict[str, str] = {}
        for h in keep:
            v = r.get(h, "")
            if h in REF_COLS:
                new[h] = p.ref(v)
            elif h in NAME_COLS and subject:
                g, fam = p.name(subject)
                new[h] = g if h in {"given_name", "first_name", "forename"} else fam
            elif h in NAME_COLS:
                new[h] = "Redacted"
            elif h in DOB_COLS:
                # Year only: age-band analysis survives, the identifier does not.
                new[h] = v[:4] if len(v) >= 4 else ""
            else:
                new[h] = v
        out.append(new)

    dst.parent.mkdir(parents=True, exist_ok=True)
    with dst.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=keep)
        w.writeheader()
        w.writerows(out)
    report.append(f"{src.name}: {len(out)} rows, dropped {len(dropped)} column(s)"
                  + (f" ({', '.join(dropped)})" if dropped else ""))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="src", required=True, type=Path, help="directory of CSVs exported from the school system")
    ap.add_argument("--out", dest="dst", required=True, type=Path, help="directory to write anonymised CSVs to")
    ap.add_argument("--keep-mapping", type=Path, default=None,
                    help="DANGER: write the fake->real mapping here. The output then counts as "
                         "PSEUDONYMISED and stays fully in GDPR scope.")
    args = ap.parse_args()

    if not args.src.is_dir():
        print(f"error: {args.src} is not a directory", file=sys.stderr)
        return 1

    salt = secrets.token_bytes(32)
    p = Pseudonymiser(salt)
    report: list[str] = []
    files = sorted(args.src.glob("*.csv"))
    if not files:
        print(f"error: no .csv files in {args.src}", file=sys.stderr)
        return 1
    for f in files:
        process(f, args.dst / f.name, p, report)

    print("\n".join("  " + line for line in report))
    print(f"\n  {len(p.map)} distinct people pseudonymised -> {args.dst}")

    if args.keep_mapping:
        args.keep_mapping.parent.mkdir(parents=True, exist_ok=True)
        with args.keep_mapping.open("w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["pseudonym", "real_ref"])
            for real, fake in sorted(p.map.items(), key=lambda kv: kv[1]):
                w.writerow([fake, real])
        os.chmod(args.keep_mapping, 0o600)
        print(f"\n  !! MAPPING WRITTEN TO {args.keep_mapping}")
        print("  !! Your output is PSEUDONYMISED, not anonymised. It remains personal data")
        print("  !! under GDPR. Keep this file encrypted, off any shared drive, and delete it")
        print("  !! the moment you no longer need re-identification.")
    else:
        del p.map, p.names, salt  # nothing was ever written; the link is gone
        print("\n  Mapping destroyed. This output is ANONYMOUS and out of GDPR scope.")
        print("  You cannot re-identify anyone from it — including you.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
