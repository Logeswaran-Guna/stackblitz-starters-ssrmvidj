-- Future Minds — core tables, mirroring the logic in src/routes/*.js and
-- src/db.js's defaultData() collections (users, studentProfiles,
-- teacherProfiles, requirements, matches, sessions, payouts).
--
-- Auth: we use Supabase's built-in auth.users (phone + OTP) instead of the
-- prototype's hand-rolled OTP store. `profiles` extends auth.users 1:1.

create extension if not exists pgcrypto;

create type user_role as enum ('PARENT', 'TEACHER', 'ADMIN');
create type requirement_status as enum ('open', 'assigned');
create type match_status as enum ('PROPOSED', 'DEMO_PROPOSED', 'DEMO_SCHEDULED', 'CONFIRMED', 'DECLINED');
create type session_status as enum ('LOGGED', 'PARENT_CONFIRMED', 'DISPUTED', 'ADMIN_VALIDATED');
-- Admin-managed lifecycle status for parent/teacher profiles and student
-- records. ACTIVE is the default; REMOVED/DELETED are both soft states
-- (the row is never actually dropped) so history, matches, and payout
-- records stay intact — only visibility/usability is affected.
create type entity_status as enum ('ACTIVE', 'IDLE', 'REMOVED', 'DELETED');

-- One row per auth.users row. Role defaults to PARENT and can only become
-- TEACHER via signup metadata — never ADMIN through public signup (see the
-- handle_new_user trigger in 0003_triggers.sql, which mirrors auth.js's
-- `finalRole = role === 'TEACHER' ? 'TEACHER' : 'PARENT'`).
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_id text unique not null,
  role user_role not null default 'PARENT',
  name text not null,
  phone text unique not null,
  email text,
  consent_at timestamptz not null default now(),
  status entity_status not null default 'ACTIVE',
  created_at timestamptz not null default now()
);

-- Up to 4 per parent, enforced by trigger (see 0003) rather than a CHECK
-- constraint, since it needs a cross-row count.
create table students (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  parent_id uuid not null references profiles(id) on delete cascade,
  student_name text,
  age_grade text,
  age int,
  gender text,
  address text,
  area_city text,
  pincode text,
  whatsapp text,
  notes text,
  prior_tutoring_experience text,    -- "Prior tutoring experience" per developer requirements spec 4.1
  status entity_status not null default 'ACTIVE',
  created_at timestamptz not null default now()
);

-- One row per subject-per-student ("Get Matched" form submission).
create table requirements (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  parent_id uuid not null references profiles(id) on delete cascade,
  student_id uuid references students(id) on delete set null,
  subject text not null,
  mode text[] not null default '{}',   -- multi-select: Online/Home Tuition/Teacher Location/Community Pooling/Flexible
  location text,
  schedule_pref text,
  pricing_type text,
  budget numeric,
  preferred_teacher_gender text,     -- 'No preference' | 'Male' | 'Female', per spec 4.1
  status requirement_status not null default 'open',
  created_at timestamptz not null default now()
);

create table teacher_profiles (
  id uuid primary key default gen_random_uuid(),
  display_id text unique,            -- same FMTEACH... issued to the profile at signup
  user_id uuid unique not null references profiles(id) on delete cascade,
  qualification text,
  experience text,
  subjects text[] not null default '{}',
  preferred_locations text[] not null default '{}',
  teaching_mode text[] not null default '{}',
  availability text[] not null default '{}',
  rate_expectation numeric,
  bank_upi_ref text,
  address text,
  area_city text,
  pincode text,
  whatsapp text,
  kyc_status text not null default 'PENDING',
  kyc_document_path text,            -- path within the private kyc-documents storage bucket
  photo_url text,                    -- path within the public avatars storage bucket
  tutoring_for text[] not null default '{}', -- Academics / Creative Learning / Soft Skills (multi-select)
  boards text[] not null default '{}',       -- State Board / CBSE / ICSE / IGCSE (multi-select, when tutoring_for includes Academics)
  rating numeric,
  created_at timestamptz not null default now()
);

-- One row per (language, teacher) so read/write/speak proficiency is
-- tracked per language rather than crammed into a single column.
create table teacher_languages (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references teacher_profiles(id) on delete cascade,
  language text not null,
  can_read boolean not null default false,
  can_write boolean not null default false,
  can_speak boolean not null default false,
  unique (teacher_id, language)
);

-- Same underlying row survives the whole PROPOSED -> DEMO -> CONFIRMED /
-- DECLINED lifecycle; its DISPLAY id is computed from status by
-- match_display_id() in 0002, except when frozen on decline.
create table matches (
  id uuid primary key default gen_random_uuid(),
  id_year int not null,
  id_seq int not null,
  frozen_display_id text,            -- set once, on decline; never cleared
  dead boolean not null default false,
  requirement_id uuid not null references requirements(id) on delete cascade,
  teacher_id uuid not null references teacher_profiles(id) on delete cascade,
  match_score numeric,
  status match_status not null default 'PROPOSED',
  demo_date date,
  demo_time_slot text,
  demo_proposed_at timestamptz,
  parent_accepted_demo boolean not null default false,
  teacher_accepted_demo boolean not null default false,
  scheduled_at timestamptz,
  declined_by text,
  decline_reason text,
  parent_approved_at timestamptz,
  created_at timestamptz not null default now()
);

create table payouts (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references teacher_profiles(id) on delete cascade,
  period text,
  gross_amount numeric not null,
  commission_percent numeric not null default 0,
  commission_deducted numeric not null,
  amount numeric not null,           -- net, after commission
  bank_upi_ref text not null,
  status text not null default 'RELEASED',
  released_at timestamptz not null default now()
);

-- Only loggable once the parent match is CONFIRMED (an FMAPPROVED... id).
create table class_sessions (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  match_id uuid not null references matches(id) on delete cascade,
  date date not null,
  time_slot text,
  duration_hours numeric,            -- computed client-side from the From/To time picker
  teacher_marked_at timestamptz not null default now(),
  parent_confirmed_at timestamptz,
  admin_validated_at timestamptz,
  status session_status not null default 'LOGGED',
  disputed_at timestamptz,
  dispute_reason text,
  amount numeric,
  payout_id uuid references payouts(id),
  created_at timestamptz not null default now()
);

-- One review per confirmed assignment (match), left by the parent, shown on
-- the teacher's own dashboard as "Parent & student appreciation" — per
-- developer requirements 4.4: "Dashboard shows hours, students, and
-- reviews... wired to real data."
create table teacher_reviews (
  id uuid primary key default gen_random_uuid(),
  match_id uuid unique not null references matches(id) on delete cascade,
  teacher_id uuid not null references teacher_profiles(id) on delete cascade,
  parent_id uuid not null references profiles(id) on delete cascade,
  student_name text,
  rating int not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

create index idx_students_parent on students(parent_id);
create index idx_requirements_parent on requirements(parent_id);
create index idx_requirements_student on requirements(student_id);
create index idx_matches_requirement on matches(requirement_id);
create index idx_matches_teacher on matches(teacher_id);
create index idx_matches_teacher_date_slot on matches(teacher_id, demo_date, demo_time_slot);
create index idx_sessions_match on class_sessions(match_id);
create index idx_payouts_teacher on payouts(teacher_id);
create index idx_teacher_reviews_teacher on teacher_reviews(teacher_id);
