-- ============================================================
-- Future Minds — Phase 10 schema sync
--
-- Adds an admin-managed lifecycle status (Active/Idle/Removed/Deleted) to
-- parent/teacher profiles and student records, with removing a parent
-- cascading to their students. Adds admin-gated RPCs so an executive can
-- register a parent+requirement or a teacher+application on a caller's
-- behalf (the actual auth account is created separately via the new
-- app/api/admin/register-* routes using the service-role key — these RPCs
-- are the second half of that flow, submitting the actual data once the
-- account exists). Nothing is ever hard-deleted; DELETED is itself just a
-- status, so history/matches/payouts stay intact.
--
-- Run this against future-minds-test AFTER 0010_phase9_reviews_dashboards.sql.
-- ============================================================

-- 1. entity_status enum + status columns ------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'entity_status') then
    create type entity_status as enum ('ACTIVE', 'IDLE', 'REMOVED', 'DELETED');
  end if;
end $$;

alter table profiles add column if not exists status entity_status not null default 'ACTIVE';
alter table students add column if not exists status entity_status not null default 'ACTIVE';

-- 2. Shared helpers + admin-gated wrappers -----------------------------------

drop function if exists _submit_requirement_for;
drop function if exists admin_register_parent_requirement;
drop function if exists _upsert_teacher_profile_for;
drop function if exists admin_register_teacher_profile;
drop function if exists admin_set_profile_status;
drop function if exists admin_set_student_status;
drop function if exists admin_parents_directory;
drop function if exists admin_teachers_directory;

create or replace function _submit_requirement_for(
  p_parent_id uuid,
  p_subject text,
  p_mode text[],
  p_location text default null,
  p_schedule_pref text default null,
  p_pricing_type text default null,
  p_budget numeric default null,
  p_preferred_teacher_gender text default null,
  p_student_id text default null,
  p_student_name text default null,
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
  v_student students;
  v_req requirements;
  v_count int;
begin
  if p_subject is null or p_mode is null or array_length(p_mode, 1) is null then
    raise exception 'Subject and at least one mode are required';
  end if;

  if p_student_id is not null then
    v_student := find_student(p_student_id, p_parent_id);
    if v_student.id is null then raise exception 'Student not found for this account'; end if;
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
    select count(*) into v_count from students where parent_id = p_parent_id;
    if v_count >= 4 then
      raise exception 'You can register up to 4 students per parent account. To add a subject for an existing student instead, pass their Student ID.';
    end if;
    insert into students (display_id, parent_id, student_name, age_grade, age, gender, address, area_city, pincode, whatsapp, notes, prior_tutoring_experience)
    values (next_daily_id('student_daily', 'FMSTU'), p_parent_id, p_student_name, p_age_grade, p_age, p_gender, p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience)
    returning * into v_student;
  end if;

  insert into requirements (display_id, parent_id, student_id, subject, mode, location, schedule_pref, pricing_type, budget, preferred_teacher_gender)
  values (next_daily_id('requirement_daily', 'FMREQ'), p_parent_id, v_student.id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget, p_preferred_teacher_gender)
  returning * into v_req;

  return v_req;
end;
$$;

create or replace function submit_requirement(
  p_subject text,
  p_mode text[],
  p_consent boolean,
  p_location text default null,
  p_schedule_pref text default null,
  p_pricing_type text default null,
  p_budget numeric default null,
  p_preferred_teacher_gender text default null,
  p_student_id text default null,
  p_student_name text default null,
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
declare me profiles := current_profile();
begin
  if me.role <> 'PARENT' then raise exception 'Only parents can submit requirements'; end if;
  if not p_consent then raise exception 'Consent to be contacted is required'; end if;
  return _submit_requirement_for(
    me.id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget,
    p_preferred_teacher_gender, p_student_id, p_student_name, p_age_grade, p_age, p_gender,
    p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience
  );
end;
$$;

create or replace function admin_register_parent_requirement(
  p_parent_id uuid,
  p_subject text,
  p_mode text[],
  p_location text default null,
  p_schedule_pref text default null,
  p_pricing_type text default null,
  p_budget numeric default null,
  p_preferred_teacher_gender text default null,
  p_student_id text default null,
  p_student_name text default null,
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
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  return _submit_requirement_for(
    p_parent_id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget,
    p_preferred_teacher_gender, p_student_id, p_student_name, p_age_grade, p_age, p_gender,
    p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience
  );
end;
$$;

create or replace function _upsert_teacher_profile_for(
  p_user_id uuid,
  p_display_id text,
  p_qualification text default null,
  p_experience text default null,
  p_subjects text[] default null,
  p_preferred_locations text[] default null,
  p_teaching_mode text[] default null,
  p_availability text[] default null,
  p_time_slot text default null,
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
  v_profile teacher_profiles;
  v_availability text[] := coalesce(p_availability, case when p_time_slot is not null then array[p_time_slot] else '{}'::text[] end);
begin
  select * into v_profile from teacher_profiles where user_id = p_user_id;

  if v_profile.id is null then
    insert into teacher_profiles (display_id, user_id, qualification, experience, subjects, preferred_locations, teaching_mode, availability, rate_expectation, bank_upi_ref, address, area_city, pincode, whatsapp, kyc_status, photo_url, tutoring_for, boards)
    values (p_display_id, p_user_id, p_qualification, p_experience, coalesce(p_subjects, '{}'), coalesce(p_preferred_locations, '{}'), coalesce(p_teaching_mode, '{}'), v_availability, p_rate_expectation, p_bank_upi_ref, p_address, p_area_city, p_pincode, p_whatsapp, 'PENDING', p_photo_url, coalesce(p_tutoring_for, '{}'), coalesce(p_boards, '{}'))
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

create or replace function upsert_teacher_profile(
  p_qualification text default null,
  p_experience text default null,
  p_subjects text[] default null,
  p_preferred_locations text[] default null,
  p_teaching_mode text[] default null,
  p_availability text[] default null,
  p_time_slot text default null,
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
declare me profiles := current_profile();
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;
  return _upsert_teacher_profile_for(
    me.id, me.display_id, p_qualification, p_experience, p_subjects, p_preferred_locations,
    p_teaching_mode, p_availability, p_time_slot, p_rate_expectation, p_bank_upi_ref,
    p_address, p_area_city, p_pincode, p_whatsapp, p_photo_url, p_tutoring_for, p_boards
  );
end;
$$;

create or replace function admin_register_teacher_profile(
  p_teacher_user_id uuid,
  p_qualification text default null,
  p_experience text default null,
  p_subjects text[] default null,
  p_preferred_locations text[] default null,
  p_teaching_mode text[] default null,
  p_availability text[] default null,
  p_time_slot text default null,
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
  v_target profiles;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  select * into v_target from profiles where id = p_teacher_user_id;
  if v_target.id is null or v_target.role <> 'TEACHER' then
    raise exception 'Teacher account not found';
  end if;

  return _upsert_teacher_profile_for(
    v_target.id, v_target.display_id, p_qualification, p_experience, p_subjects, p_preferred_locations,
    p_teaching_mode, p_availability, p_time_slot, p_rate_expectation, p_bank_upi_ref,
    p_address, p_area_city, p_pincode, p_whatsapp, p_photo_url, p_tutoring_for, p_boards
  );
end;
$$;

-- 3. Manage Users: status changes + directory --------------------------------

create or replace function admin_set_profile_status(p_profile_id uuid, p_status entity_status)
returns profiles
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_target profiles;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  update profiles set status = p_status where id = p_profile_id returning * into v_target;
  if v_target.id is null then raise exception 'Profile not found'; end if;

  if v_target.role = 'PARENT' and p_status in ('REMOVED', 'DELETED') then
    update students set status = p_status where parent_id = v_target.id;
  end if;

  return v_target;
end;
$$;

create or replace function admin_set_student_status(p_student_id uuid, p_status entity_status)
returns students
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_student students;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  update students set status = p_status where id = p_student_id returning * into v_student;
  if v_student.id is null then raise exception 'Student not found'; end if;

  return v_student;
end;
$$;

create or replace function admin_parents_directory()
returns table (
  id uuid, display_id text, name text, phone text, email text,
  status entity_status, created_at timestamptz, students jsonb
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
  select p.id, p.display_id, p.name, p.phone, p.email, p.status, p.created_at,
    coalesce(
      (select jsonb_agg(
          jsonb_build_object(
            'id', s.id, 'display_id', s.display_id, 'student_name', s.student_name,
            'age_grade', s.age_grade, 'status', s.status
          ) order by s.created_at
        )
       from students s where s.parent_id = p.id),
      '[]'::jsonb
    )
  from profiles p
  where p.role = 'PARENT'
  order by p.created_at desc;
end;
$$;

-- === teachers.js: GET /teachers (admin directory, ?subject=) — adds status ===
create or replace function admin_teachers_directory(p_subject text default null)
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], rate_expectation numeric,
  bank_upi_ref text, kyc_status text, kyc_document_path text, photo_url text,
  tutoring_for text[], boards text[], rating numeric,
  languages jsonb,
  total_hours numeric, students_trained int, active_batches int,
  rating_avg numeric, rating_count int,
  user_id uuid, status entity_status
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
    ),
    coalesce((select sum(cs.duration_hours) from class_sessions cs join matches m on m.id = cs.match_id where m.teacher_id = t.id and cs.status <> 'DISPUTED'), 0),
    coalesce((select count(distinct r.student_id) from matches m join requirements r on r.id = m.requirement_id where m.teacher_id = t.id and m.status = 'CONFIRMED'), 0)::int,
    coalesce((select count(*) from matches m where m.teacher_id = t.id and m.status = 'CONFIRMED'), 0)::int,
    (select round(avg(tr.rating), 1) from teacher_reviews tr where tr.teacher_id = t.id),
    coalesce((select count(*) from teacher_reviews tr where tr.teacher_id = t.id), 0)::int,
    u.id, u.status
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where p_subject is null or p_subject = any(t.subjects);
end;
$$;

-- 4. Re-apply function grants -------------------------------------------------

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
