-- ============================================================================
-- 002_org.sql — school structure, people, enrolment, and TEACHING TIME
--
-- The lesson tables exist because the thesis question is "which periods and
-- content hurt progress". Without recorded contact time and lesson-level
-- attendance, a weak topic is indistinguishable between three causes:
--   (a) it was taught badly,       (b) it got two lessons instead of eight,
--   (c) the student was not in the room.
-- (a) is a teaching finding, (b) a curriculum-design finding, (c) neither.
-- A platform that cannot separate them will confidently blame the wrong party.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Calendar
-- ---------------------------------------------------------------------------
CREATE TABLE org.academic_year (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  label       text NOT NULL,                  -- '2025-2026'
  starts_on   date NOT NULL,
  ends_on     date NOT NULL,
  is_current  boolean NOT NULL DEFAULT false,
  CHECK (ends_on > starts_on),
  UNIQUE (tenant_id, label)
);
CREATE UNIQUE INDEX academic_year_one_current ON org.academic_year (tenant_id)
  WHERE is_current;

-- A reporting period: MYP term, DP semester, Greek τετράμηνο, UK half-term.
CREATE TABLE org.term (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  academic_year_id  uuid NOT NULL REFERENCES org.academic_year(id) ON DELETE CASCADE,
  label             text NOT NULL,
  seq               smallint NOT NULL,        -- 1,2,3... ordering within the year
  starts_on         date NOT NULL,
  ends_on           date NOT NULL,
  is_reporting      boolean NOT NULL DEFAULT true,
  CHECK (ends_on > starts_on),
  UNIQUE (tenant_id, academic_year_id, seq)
);
CREATE INDEX term_dates_ix ON org.term (tenant_id, starts_on, ends_on);

-- ---------------------------------------------------------------------------
-- People. One table, discriminated — a guardian can also be staff, and a
-- sixth-form student can be a peer tutor.
-- ---------------------------------------------------------------------------
CREATE TABLE org.person (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  external_ref  text,                         -- the school MIS/SIS id
  given_name    text NOT NULL,
  family_name   text NOT NULL,
  preferred_name text,
  date_of_birth date,
  user_id       uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  is_staff      boolean NOT NULL DEFAULT false,
  is_student    boolean NOT NULL DEFAULT false,
  -- Provisional: created inline by a teacher who needed to mark someone not yet
  -- on the roster (mid-term arrival, external candidate, visiting student).
  -- Without this, entry blocks on an administrator and the marks never land.
  is_provisional boolean NOT NULL DEFAULT false,
  joined_on     date,
  left_on       date,
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);
CREATE UNIQUE INDEX person_external_uq ON org.person (tenant_id, external_ref)
  WHERE external_ref IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX person_tenant_ix ON org.person (tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX person_provisional_ix ON org.person (tenant_id) WHERE is_provisional;

CREATE TABLE org.guardian_link (
  tenant_id   uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  student_id  uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  guardian_id uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  relation    text,
  PRIMARY KEY (tenant_id, student_id, guardian_id)
);

-- ---------------------------------------------------------------------------
-- Subjects and classes
-- ---------------------------------------------------------------------------
CREATE TABLE org.department (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  name      text NOT NULL,
  UNIQUE (tenant_id, name)
);

CREATE TABLE org.subject (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  department_id  uuid REFERENCES org.department(id) ON DELETE SET NULL,
  code           text NOT NULL,
  name           text NOT NULL,
  UNIQUE (tenant_id, code)
);

-- The class a teacher actually stands in front of. Framework binding lives HERE
-- and is NULLABLE: a group with no framework still records marks and still gets
-- trajectory analytics. Requiring framework config before the first keystroke
-- is how this product would die in pilot.
CREATE TABLE org.teaching_group (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  academic_year_id     uuid NOT NULL REFERENCES org.academic_year(id) ON DELETE CASCADE,
  subject_id           uuid NOT NULL REFERENCES org.subject(id) ON DELETE CASCADE,
  label                text NOT NULL,          -- '11Hi/2', 'Γ2 Ανθρωπιστικών'
  year_level           text,                   -- 'MYP4', 'DP1', 'Γ Λυκείου', 'Y11'
  -- Nullable on purpose. See comment above.
  framework_version_id uuid,                   -- FK added in 003
  level_code           text,                   -- 'HL','SL','Higher','Foundation','Extended'
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, academic_year_id, subject_id, label)
);
CREATE INDEX teaching_group_year_ix ON org.teaching_group (tenant_id, academic_year_id);

CREATE TABLE org.enrolment (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  student_id        uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  teaching_group_id uuid NOT NULL REFERENCES org.teaching_group(id) ON DELETE CASCADE,
  from_date         date NOT NULL DEFAULT current_date,
  to_date           date,
  CHECK (to_date IS NULL OR to_date >= from_date)
);
CREATE UNIQUE INDEX enrolment_active_uq ON org.enrolment (tenant_id, student_id, teaching_group_id)
  WHERE to_date IS NULL;
CREATE INDEX enrolment_group_ix ON org.enrolment (tenant_id, teaching_group_id);
CREATE INDEX enrolment_student_ix ON org.enrolment (tenant_id, student_id);

-- Dated teaching assignments: "the teacher changed in January" must be
-- queryable, because it is one of the most common causes of a period effect.
CREATE TABLE org.teaching_assignment (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  staff_id          uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  teaching_group_id uuid NOT NULL REFERENCES org.teaching_group(id) ON DELETE CASCADE,
  role              text NOT NULL DEFAULT 'primary'
                      CHECK (role IN ('primary','co_teacher','support','cover','moderator')),
  from_date         date NOT NULL DEFAULT current_date,
  to_date           date,
  CHECK (to_date IS NULL OR to_date >= from_date)
);
CREATE INDEX teaching_assignment_staff_ix ON org.teaching_assignment (tenant_id, staff_id);
CREATE INDEX teaching_assignment_group_ix ON org.teaching_assignment (tenant_id, teaching_group_id);

-- Homeroom / tutor / φροντιστής: the pastoral view across all of a student's
-- subjects, which is a different access scope from subject teaching.
CREATE TABLE org.tutor_assignment (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  staff_id    uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  student_id  uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  from_date   date NOT NULL DEFAULT current_date,
  to_date     date
);
CREATE INDEX tutor_assignment_staff_ix ON org.tutor_assignment (tenant_id, staff_id);

-- ---------------------------------------------------------------------------
-- TEACHING TIME — the attribution layer
-- ---------------------------------------------------------------------------
CREATE TABLE org.lesson (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  teaching_group_id uuid NOT NULL REFERENCES org.teaching_group(id) ON DELETE CASCADE,
  held_on           date NOT NULL,
  minutes           smallint NOT NULL DEFAULT 45 CHECK (minutes > 0 AND minutes <= 600),
  taught_by_id      uuid REFERENCES org.person(id) ON DELETE SET NULL,
  was_cancelled     boolean NOT NULL DEFAULT false,
  topic_tag_id      uuid,                      -- FK added in 004
  note              text
);
CREATE INDEX lesson_group_date_ix ON org.lesson (tenant_id, teaching_group_id, held_on);
CREATE INDEX lesson_topic_ix ON org.lesson (tenant_id, topic_tag_id) WHERE topic_tag_id IS NOT NULL;

-- Recorded only where the school already takes registers. Absent rows mean
-- "not tracked", never "present" — analytics must check coverage before using it.
CREATE TABLE org.lesson_attendance (
  tenant_id  uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  lesson_id  uuid NOT NULL REFERENCES org.lesson(id) ON DELETE CASCADE,
  student_id uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  status     text NOT NULL CHECK (status IN ('present','absent','late','excused','remote')),
  PRIMARY KEY (tenant_id, lesson_id, student_id)
);
CREATE INDEX lesson_attendance_student_ix ON org.lesson_attendance (tenant_id, student_id);

-- ---------------------------------------------------------------------------
-- Bootstrap. Every design the panel produced forgot that on day one the
-- database is empty and somebody must get 900 students into it.
-- ---------------------------------------------------------------------------
CREATE TABLE org.import_batch (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  kind         text NOT NULL CHECK (kind IN
                 ('students','staff','groups','enrolments','timetable','marks','curriculum')),
  source       text NOT NULL DEFAULT 'csv' CHECK (source IN ('csv','xlsx','sis_api','manual')),
  filename     text,
  uploaded_by  uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  uploaded_at  timestamptz NOT NULL DEFAULT now(),
  row_count    integer,
  ok_count     integer,
  error_count  integer,
  status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','validating','ready','applied','failed','rolled_back')),
  report       jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX import_batch_tenant_ix ON org.import_batch (tenant_id, uploaded_at DESC);

-- Staging: every import lands here first so a teacher sees what will happen
-- before it happens, and so a bad import is one DELETE rather than an incident.
CREATE TABLE org.import_row (
  id         bigserial PRIMARY KEY,
  tenant_id  uuid NOT NULL,
  batch_id   uuid NOT NULL REFERENCES org.import_batch(id) ON DELETE CASCADE,
  line_no    integer NOT NULL,
  payload    jsonb NOT NULL,
  status     text NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','ok','warning','error','skipped')),
  message    text,
  target_id  uuid
);
CREATE INDEX import_row_batch_ix ON org.import_row (batch_id, status);
