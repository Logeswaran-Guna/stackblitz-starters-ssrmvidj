-- One-time cleanup for the tutor-fm project specifically: drops the old
-- flat MVP tables (no auth, no matching workflow) that this migration set
-- replaces. Confirmed with the founder that these hold only test
-- submissions, not real production data, so no data migration is needed.
-- Safe to skip this file if applying the schema to a brand-new project
-- that never had these tables.
drop table if exists requirements cascade;
drop table if exists tutors cascade;
