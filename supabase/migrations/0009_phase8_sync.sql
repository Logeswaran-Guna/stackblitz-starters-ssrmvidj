-- ============================================================
-- Future Minds — Phase 8 schema sync
--
-- Brings a database that already has migrations 0001-0007 applied (the
-- state future-minds-test was left in after the KYC/storage phase) up to
-- the current state of this repo's 0001/0004/0005/0006/0008 files, which
-- were edited in place during Phase 8 (categories rework: array modes,
-- teacher photo, Tutoring For / Boards, Languages Known).
--
-- Safe to paste into the Supabase SQL editor and run once. Column changes
-- and RLS/storage policies are guarded so re-running is harmless; the RPC
-- functions are dropped and recreated because their signatures/return
-- shapes changed in ways `create or replace` cannot express.
-- ============================================================

-- 1. Column type / addition changes -----------------------------------------

-- requirements.mode: text -> text[] (existing scalar values become a
-- single-element array; a column that's already text[] is left untouched)
do $$
begin
  if (select data_type from information_schema.columns
      where table_name = 'requirements' and column_name = 'mode') = 'text' then
    alter table requirements
      alter column mode type text[] using case when mode is null then '{}'::text[] else array[mode] end,
      alter column mode set default '{}',
      alter column mode set not null;
  end if;
end $$;

-- teacher_profiles.teaching_mode: text -> text[]
do $$
begin
  if (select data_type from information_schema.columns
      where table_name = 'teacher_profiles' and column_name = 'teaching_mode') = 'text' then
    alter table teacher_profiles
      alter column teaching_mode type text[] using case when teaching_mode is null then '{}'::text[] else array[teaching_mode] end,
      alter column teaching_mode set default '{}',
      alter column teaching_mode set not null;
  end if;
end $$;

alter table teacher_profiles
  add column if not exists photo_url text,
  add column if not exists tutoring_for text[] not null default '{}',
  add column if not exists boards text[] not null default '{}';

-- 2. teacher_languages table (Languages Known: dynamic add/remove list) -----

create table if not exists teacher_languages (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references teacher_profiles(id) on delete cascade,
  language text not null,
  can_read boolean not null default false,
  can_write boolean not null default false,
  can_speak boolean not null default false,
  unique (teacher_id, language)
);

alter table teacher_languages enable row level security;

drop policy if exists teacher_languages_select on teacher_languages;
create policy teacher_languages_select on teacher_languages for select
  using (
    is_admin()
    or teacher_id in (select id from teacher_profiles where user_id = auth.uid())
    or teacher_id in (
      select m.teacher_id from matches m
      join requirements r on r.id = m.requirement_id
      where r.parent_id = auth.uid()
    )
  );

revoke all on teacher_languages from authenticated, anon;
grant select on teacher_languages to authenticated;

-- 3. is_admin(): SECURITY DEFINER recursion fix (safe to re-apply) ---------

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'ADMIN');
$$;

-- 4. RPCs whose parameter list or return shape changed ----------------------
-- (drop first: create-or-replace can't change an existing param's type or a
-- table-returning function's output columns)

drop function if exists submit_requirement;
drop function if exists upsert_teacher_profile;
drop function if exists admin_requirements_queue;
drop function if exists admin_teachers_directory;
drop function if exists my_requirements;
drop function if exists my_teacher_profile;
drop function if exists set_teacher_languages;

-- === requirements.js: POST /requirements ===================================
create or replace function submit_requirement(
  p_subject text,
  p_mode text[],
  p_consent boolean,
  p_location text default null,
  p_schedule_pref text default null,
  p_pricing_type text default null,
  p_budget numeric default null,
  p_preferred_teacher_gender text default null,
  p_student_id text default null,       -- pass to enroll an EXISTING student in another subject
  p_student_name text default null,     -- pass (with age_grade) to register a NEW student
  p_age_grade text default null,
  p_age int default null,
  p_gender text default null,
  p_address text default null,
  p_area_city text default null,
  p_pincode text default null,
  p_whatsapp text default null,
  p_notes text default null,
  p_prior_tutoring_experience text default null
)
returns requirements
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_student students;
  v_req requirements;
  v_count int;
begin
  if me.role <> 'PARENT' then raise exception 'Only parents can submit requirements'; end if;
  if not p_consent then raise exception 'Consent to be contacted is required'; end if;
  if p_subject is null or p_mode is null or array_length(p_mode, 1) is null then
    raise exception 'Subject and at least one mode are required';
  end if;

  if p_student_id is not null then
    v_student := find_student(p_student_id, me.id);
    if v_student.id is null then raise exception 'Student not found for your account'; end if;
    update students set
      address = coalesce(p_address, address),
      area_city = coalesce(p_area_city, area_city),
      pincode = coalesce(p_pincode, pincode),
      whatsapp = coalesce(p_whatsapp, whatsapp),
      notes = coalesce(p_notes, notes),
      prior_tutoring_experience = coalesce(p_prior_tutoring_experience, prior_tutoring_experience)
    where id = v_student.id
    returning * into v_student;
  elsif p_student_name is not null or p_age_grade is not null then
    select count(*) into v_count from students where parent_id = me.id;
    if v_count >= 4 then
      raise exception 'You can register up to 4 students per parent account. To add a subject for an existing student instead, pass their Student ID.';
    end if;
    insert into students (display_id, parent_id, student_name, age_grade, age, gender, address, area_city, pincode, whatsapp, notes, prior_tutoring_experience)
    values (next_daily_id('student_daily', 'FMSTU'), me.id, p_student_name, p_age_grade, p_age, p_gender, p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience)
    returning * into v_student;
  end if;

  insert into requirements (display_id, parent_id, student_id, subject, mode, location, schedule_pref, pricing_type, budget, preferred_teacher_gender)
  values (next_daily_id('requirement_daily', 'FMREQ'), me.id, v_student.id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget, p_preferred_teacher_gender)
  returning * into v_req;

  return v_req;
end;
$$;

-- === teachers.js: PUT /teachers/me =========================================
create or replace function upsert_teacher_profile(
  p_qualification text default null,
  p_experience text default null,
  p_subjects text[] default null,
  p_preferred_locations text[] default null,
  p_teaching_mode text[] default null,
  p_availability text[] default null,
  p_time_slot text default null,        -- single-slot dropdown shorthand for availability
  p_rate_expectation numeric default null,
  p_bank_upi_ref text default null,
  p_address text default null,
  p_area_city text default null,
  p_pincode text default null,
  p_whatsapp text default null,
  p_photo_url text default null,
  p_tutoring_for text[] default null,
  p_boards text[] default null
)
returns teacher_profiles
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_profile teacher_profiles;
  v_availability text[] := coalesce(p_availability, case when p_time_slot is not null then array[p_time_slot] else '{}'::text[] end);
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;

  select * into v_profile from teacher_profiles where user_id = me.id;

  if v_profile.id is null then
    insert into teacher_profiles (display_id, user_id, qualification, experience, subjects, preferred_locations, teaching_mode, availability, rate_expectation, bank_upi_ref, address, area_city, pincode, whatsapp, kyc_status, photo_url, tutoring_for, boards)
    values (me.display_id, me.id, p_qualification, p_experience, coalesce(p_subjects, '{}'), coalesce(p_preferred_locations, '{}'), coalesce(p_teaching_mode, '{}'), v_availability, p_rate_expectation, p_bank_upi_ref, p_address, p_area_city, p_pincode, p_whatsapp, 'PENDING', p_photo_url, coalesce(p_tutoring_for, '{}'), coalesce(p_boards, '{}'))
    returning * into v_profile;
  else
    update teacher_profiles set
      qualification = coalesce(p_qualification, qualification),
      experience = coalesce(p_experience, experience),
      subjects = case when p_subjects is not null and array_length(p_subjects, 1) > 0 then p_subjects else subjects end,
      preferred_locations = case when p_preferred_locations is not null and array_length(p_preferred_locations, 1) > 0 then p_preferred_locations else preferred_locations end,
      teaching_mode = case when p_teaching_mode is not null and array_length(p_teaching_mode, 1) > 0 then p_teaching_mode else teaching_mode end,
      availability = case when array_length(v_availability, 1) > 0 then v_availability else availability end,
      rate_expectation = coalesce(p_rate_expectation, rate_expectation),
      bank_upi_ref = coalesce(p_bank_upi_ref, bank_upi_ref),
      address = coalesce(p_address, address),
      area_city = coalesce(p_area_city, area_city),
      pincode = coalesce(p_pincode, pincode),
      whatsapp = coalesce(p_whatsapp, whatsapp),
      photo_url = coalesce(p_photo_url, photo_url),
      tutoring_for = case when p_tutoring_for is not null and array_length(p_tutoring_for, 1) > 0 then p_tutoring_for else tutoring_for end,
      boards = case when p_boards is not null and array_length(p_boards, 1) > 0 then p_boards else boards end
    where id = v_profile.id
    returning * into v_profile;
  end if;

  return v_profile;
end;
$$;

-- === requirements.js: GET /requirements/mine ================================
create or replace function my_requirements()
returns table (
  id uuid, display_id text, subject text, mode text[], location text,
  schedule_pref text, pricing_type text, budget numeric, status requirement_status,
  created_at timestamptz, student_display_id text, student_name text, student_grade text,
  match_id uuid, match_label text, match_status match_status,
  demo_date date, parent_accepted_demo boolean, teacher_accepted_demo boolean,
  teacher_display_id text, teacher_name text, teacher_phone text,
  time_slot text
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'PARENT' then raise exception 'Parent only'; end if;

  return query
  select
    r.id, r.display_id, r.subject, r.mode, r.location, r.schedule_pref, r.pricing_type, r.budget, r.status, r.created_at,
    s.display_id, s.student_name, s.age_grade,
    bm.id, case when bm.id is not null then match_display_id(bm) else null end, bm.status,
    bm.demo_date, bm.parent_accepted_demo, bm.teacher_accepted_demo,
    tp.display_id, tu.name, tu.phone,
    coalesce(bm.demo_time_slot, r.schedule_pref)
  from requirements r
  left join students s on s.id = r.student_id
  left join lateral (
    select m.* from matches m
    where m.requirement_id = r.id and m.status <> 'DECLINED'
    order by (m.status = 'CONFIRMED') desc, m.created_at desc
    limit 1
  ) bm on true
  left join teacher_profiles tp on tp.id = bm.teacher_id
  left join profiles tu on tu.id = tp.user_id
  where r.parent_id = me.id
  order by r.created_at desc;
end;
$$;

-- === requirements.js: GET /requirements (admin queue) ========================
create or replace function admin_requirements_queue()
returns table (
  id uuid, display_id text, subject text, mode text[], location text, schedule_pref text,
  budget numeric, preferred_teacher_gender text, status requirement_status, created_at timestamptz,
  parent_display_id text, parent_name text, parent_phone text,
  student_display_id text, student_name text, student_grade text,
  match_id uuid, match_label text, match_status match_status, match_score numeric,
  demo_date date, demo_time_slot text, parent_accepted_demo boolean, teacher_accepted_demo boolean,
  teacher_id uuid, teacher_display_id text, teacher_name text
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
  select r.id, r.display_id, r.subject, r.mode, r.location, r.schedule_pref, r.budget, r.preferred_teacher_gender, r.status, r.created_at,
    p.display_id, p.name, p.phone,
    s.display_id, s.student_name, s.age_grade,
    bm.id, case when bm.id is not null then match_display_id(bm) else null end, bm.status, bm.match_score,
    bm.demo_date, bm.demo_time_slot, bm.parent_accepted_demo, bm.teacher_accepted_demo,
    tp.id, tp.display_id, tu.name
  from requirements r
  join profiles p on p.id = r.parent_id
  left join students s on s.id = r.student_id
  left join lateral (
    select m.* from matches m
    where m.requirement_id = r.id and m.status <> 'DECLINED'
    order by (m.status = 'CONFIRMED') desc, m.created_at desc
    limit 1
  ) bm on true
  left join teacher_profiles tp on tp.id = bm.teacher_id
  left join profiles tu on tu.id = tp.user_id
  order by r.created_at desc;
end;
$$;

-- === teachers.js: GET /teachers (admin directory, ?subject=) =================
create or replace function admin_teachers_directory(p_subject text default null)
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], rate_expectation numeric,
  bank_upi_ref text, kyc_status text, kyc_document_path text, photo_url text,
  tutoring_for text[], boards text[], rating numeric,
  languages jsonb
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
  select t.id, t.display_id, u.name, u.phone, u.email, t.qualification, t.experience,
    t.subjects, t.preferred_locations, t.teaching_mode, t.availability, t.rate_expectation,
    t.bank_upi_ref, t.kyc_status, t.kyc_document_path, t.photo_url,
    t.tutoring_for, t.boards, t.rating,
    coalesce(
      (select jsonb_agg(jsonb_build_object('language', tl.language, 'can_read', tl.can_read, 'can_write', tl.can_write, 'can_speak', tl.can_speak))
       from teacher_languages tl where tl.teacher_id = t.id),
      '[]'::jsonb
    )
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where p_subject is null or p_subject = any(t.subjects);
end;
$$;

-- === teacher's own full profile (for the editable Teacher Profile page) ===
create or replace function my_teacher_profile()
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], rate_expectation numeric, bank_upi_ref text,
  kyc_status text, kyc_document_path text, photo_url text,
  tutoring_for text[], boards text[], rating numeric,
  languages jsonb
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;

  return query
  select t.id, t.display_id, u.name, u.phone, u.email, t.qualification, t.experience,
    t.subjects, t.preferred_locations, t.teaching_mode, t.availability, t.rate_expectation,
    t.bank_upi_ref, t.kyc_status, t.kyc_document_path, t.photo_url,
    t.tutoring_for, t.boards, t.rating,
    coalesce(
      (select jsonb_agg(jsonb_build_object('language', tl.language, 'can_read', tl.can_read, 'can_write', tl.can_write, 'can_speak', tl.can_speak))
       from teacher_languages tl where tl.teacher_id = t.id),
      '[]'::jsonb
    )
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where t.user_id = me.id;
end;
$$;

-- === Languages Known: replace-all save (teacher edits their full list at once) ===
-- p_languages: jsonb array like [{"language":"Hindi","can_read":true,"can_write":true,"can_speak":true}, ...]
create or replace function set_teacher_languages(p_languages jsonb)
returns setof teacher_languages
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_teacher teacher_profiles;
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;

  select * into v_teacher from teacher_profiles where user_id = me.id;
  if v_teacher.id is null then raise exception 'Complete your teacher profile first'; end if;

  delete from teacher_languages where teacher_id = v_teacher.id;

  insert into teacher_languages (teacher_id, language, can_read, can_write, can_speak)
  select
    v_teacher.id,
    item->>'language',
    coalesce((item->>'can_read')::boolean, false),
    coalesce((item->>'can_write')::boolean, false),
    coalesce((item->>'can_speak')::boolean, false)
  from jsonb_array_elements(coalesce(p_languages, '[]'::jsonb)) as item
  where item->>'language' is not null and item->>'language' <> '';

  return query select * from teacher_languages where teacher_id = v_teacher.id;
end;
$$;

-- 5. avatars public storage bucket (teacher profile photos) -----------------

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists avatars_public_read on storage.objects;
create policy avatars_public_read on storage.objects for select
  using (bucket_id = 'avatars');

drop policy if exists avatars_teacher_insert_own on storage.objects;
create policy avatars_teacher_insert_own on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists avatars_teacher_update_own on storage.objects;
create policy avatars_teacher_update_own on storage.objects for update
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists avatars_teacher_delete_own on storage.objects;
create policy avatars_teacher_delete_own on storage.objects for delete
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 6. Re-apply function grants -------------------------------------------------
-- Postgres grants EXECUTE on every new/replaced function to PUBLIC by
-- default; revoke that, then grant only to logged-in users (mirrors 0006).
revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
