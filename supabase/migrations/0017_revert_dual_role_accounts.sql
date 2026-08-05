-- Rollback of 0016: each role requires its own account after all — a
-- Parent registering as a Teacher (or vice versa) must use a different
-- email and mobile number, not the same login. Restores the original
-- strict single-role checks on every function 0016 relaxed. The
-- "already registered as a Parent/Teacher, use a different email" logic
-- now lives in lib/supabase/auth-helpers.ts (signUpOrSignIn), which
-- checks this before ever reaching these RPCs.
--
-- Safe to run whether or not 0016 was ever applied — this just sets each
-- function back to its strict form either way.

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

create or replace function my_teacher_profile()
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], rate_expectation numeric, bank_upi_ref text,
  kyc_status text, kyc_document_path text, photo_url text,
  tutoring_for text[], boards text[], rating numeric,
  languages jsonb,
  total_hours numeric, students_trained int, active_batches int,
  rating_avg numeric, rating_count int,
  status entity_status
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;
  perform _recompute_status(me.id);

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
    u.status
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where t.user_id = me.id;
end;
$$;

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
  perform _recompute_status(me.id);

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

create or replace function set_kyc_document(p_path text)
returns teacher_profiles
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_profile teacher_profiles;
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;

  update teacher_profiles
  set kyc_document_path = p_path, kyc_status = 'PENDING'
  where user_id = me.id
  returning * into v_profile;

  if v_profile.id is null then raise exception 'Complete your teacher profile before uploading KYC documents'; end if;
  return v_profile;
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
declare
  me profiles := current_profile();
  v_recent_count int;
begin
  if me.role <> 'PARENT' then raise exception 'Only parents can submit requirements'; end if;
  if not p_consent then raise exception 'Consent to be contacted is required'; end if;

  select count(*) into v_recent_count from requirements
    where parent_id = me.id and created_at > now() - interval '10 minutes';
  if v_recent_count >= 15 then
    raise exception 'Too many requirements submitted recently. Please wait a few minutes and try again, or contact us directly if you need to add more.';
  end if;

  return _submit_requirement_for(
    me.id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget,
    p_preferred_teacher_gender, p_student_id, p_student_name, p_age_grade, p_age, p_gender,
    p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience
  );
end;
$$;
