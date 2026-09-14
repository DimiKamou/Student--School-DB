-- ============================================================================
-- 004_curriculum.sql — what was being tested, and how it gets tagged
--
-- Tagging is the make-or-break of this product. Without tags there is no
-- content-level diagnosis and the thesis has nothing to say; with heavy tagging
-- teachers quit in week three. So tagging is a LADDER, and every rung is
-- optional:
--   rung 0  nothing tagged            -> trajectory analytics still work
--   rung 1  one dropdown on the test  -> topic analytics work
--   rung 2  question groups tagged    -> content-level diagnosis works
--   rung 3  per-item skill/AO tagged  -> skill profile works
-- Rung 1 is a single nullable column on the assessment. It must never require
-- knowing a join table exists.
-- ============================================================================

CREATE TABLE curric.taxonomy (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id uuid NOT NULL DEFAULT app.global_tenant()
                    REFERENCES platform.tenant(id) ON DELETE CASCADE,
  code            text NOT NULL,
  name            text NOT NULL,
  -- The axis this taxonomy classifies. Analytics is parameterised on this, not
  -- hardcoded to 'topic' — the product promises periods, subjects, topics,
  -- SKILLS and content types, and three of those are not topics.
  axis            text NOT NULL CHECK (axis IN
                    ('topic','skill','content_type','command_term','cognitive_level',
                     'global_context','key_concept','atl')),
  framework_id    uuid REFERENCES ref.framework(id) ON DELETE CASCADE,
  subject_id      uuid REFERENCES org.subject(id) ON DELETE CASCADE,
  source_ref      text,                         -- 'IB Sciences guide 2022', 'ΙΕΠ ΦΕΚ ...'
  UNIQUE (owner_tenant_id, code)
);

CREATE TABLE curric.tag (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  taxonomy_id  uuid NOT NULL REFERENCES curric.taxonomy(id) ON DELETE CASCADE,
  parent_id    uuid REFERENCES curric.tag(id) ON DELETE CASCADE,
  code         text NOT NULL,
  label        text NOT NULL,
  sort_order   smallint NOT NULL DEFAULT 0,
  is_leaf      boolean NOT NULL DEFAULT true,
  -- Nominal teaching time, if the curriculum specifies it. Compared against
  -- actual delivered minutes from org.lesson to separate "taught badly" from
  -- "never got the hours".
  nominal_minutes integer CHECK (nominal_minutes IS NULL OR nominal_minutes >= 0),
  UNIQUE (taxonomy_id, code)
);
CREATE INDEX tag_parent_ix ON curric.tag (parent_id);
CREATE INDEX tag_taxonomy_ix ON curric.tag (taxonomy_id);

-- Real closure table. A materialised dotted path would make "everything under
-- this ΙΕΠ ενότητα" a LIKE scan and make re-parenting a topic unsafe.
CREATE TABLE curric.tag_closure (
  ancestor_id   uuid NOT NULL REFERENCES curric.tag(id) ON DELETE CASCADE,
  descendant_id uuid NOT NULL REFERENCES curric.tag(id) ON DELETE CASCADE,
  distance      smallint NOT NULL CHECK (distance >= 0),
  PRIMARY KEY (ancestor_id, descendant_id)
);
CREATE INDEX tag_closure_desc_ix ON curric.tag_closure (descendant_id, distance);

CREATE OR REPLACE FUNCTION curric.tg_tag_closure() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO curric.tag_closure (ancestor_id, descendant_id, distance)
    VALUES (NEW.id, NEW.id, 0);
    IF NEW.parent_id IS NOT NULL THEN
      INSERT INTO curric.tag_closure (ancestor_id, descendant_id, distance)
      SELECT c.ancestor_id, NEW.id, c.distance + 1
      FROM curric.tag_closure c WHERE c.descendant_id = NEW.parent_id
      ON CONFLICT DO NOTHING;
      UPDATE curric.tag SET is_leaf = false WHERE id = NEW.parent_id AND is_leaf;
    END IF;
  ELSIF TG_OP = 'UPDATE' AND NEW.parent_id IS DISTINCT FROM OLD.parent_id THEN
    -- Re-parent: drop every edge from outside the subtree into it, then rebuild.
    DELETE FROM curric.tag_closure
    WHERE descendant_id IN (SELECT descendant_id FROM curric.tag_closure WHERE ancestor_id = NEW.id)
      AND ancestor_id NOT IN (SELECT descendant_id FROM curric.tag_closure WHERE ancestor_id = NEW.id);
    IF NEW.parent_id IS NOT NULL THEN
      INSERT INTO curric.tag_closure (ancestor_id, descendant_id, distance)
      SELECT up.ancestor_id, down.descendant_id, up.distance + down.distance + 1
      FROM curric.tag_closure up, curric.tag_closure down
      WHERE up.descendant_id = NEW.parent_id AND down.ancestor_id = NEW.id
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER tag_closure_maintain
  AFTER INSERT OR UPDATE OF parent_id ON curric.tag
  FOR EACH ROW EXECUTE FUNCTION curric.tg_tag_closure();

ALTER TABLE org.lesson
  ADD CONSTRAINT lesson_topic_fk FOREIGN KEY (topic_tag_id)
  REFERENCES curric.tag(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- Examinable scope: "was this topic actually in the ύλη when I taught it?"
-- Greek ύλη changes by ΥΑ every year; UK specs drop content. source_ref means
-- the answer cites the document rather than asserting it.
-- ---------------------------------------------------------------------------
CREATE TABLE curric.tag_inclusion (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid REFERENCES platform.tenant(id) ON DELETE CASCADE,  -- NULL = global
  tag_id      uuid NOT NULL REFERENCES curric.tag(id) ON DELETE CASCADE,
  academic_year_label text NOT NULL,
  is_examinable boolean NOT NULL DEFAULT true,
  source_ref   text
);
CREATE UNIQUE INDEX tag_inclusion_uq ON curric.tag_inclusion
  (coalesce(tenant_id, app.global_tenant()), tag_id, academic_year_label);

-- ---------------------------------------------------------------------------
-- Reusable blueprints: last year's paper, cloned. The cheapest tagging is
-- tagging you did once and never repeat.
-- ---------------------------------------------------------------------------
CREATE TABLE curric.blueprint (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  subject_id        uuid REFERENCES org.subject(id) ON DELETE SET NULL,
  framework_version_id uuid REFERENCES ref.framework_version(id) ON DELETE SET NULL,
  name              text NOT NULL,
  description       text,
  created_by        uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  times_used        integer NOT NULL DEFAULT 0,
  is_shared         boolean NOT NULL DEFAULT false   -- visible department-wide
);
CREATE INDEX blueprint_tenant_ix ON curric.blueprint (tenant_id, subject_id);

CREATE TABLE curric.blueprint_item (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  blueprint_id  uuid NOT NULL REFERENCES curric.blueprint(id) ON DELETE CASCADE,
  seq           smallint NOT NULL,
  label         text NOT NULL,                  -- 'Q1a', 'Κριτήριο Β'
  max_value     numeric(10,4),
  measure_id    uuid REFERENCES ref.measure(id) ON DELETE SET NULL,
  topic_tag_id  uuid REFERENCES curric.tag(id) ON DELETE SET NULL,
  skill_tag_id  uuid REFERENCES curric.tag(id) ON DELETE SET NULL,
  UNIQUE (blueprint_id, seq)
);
