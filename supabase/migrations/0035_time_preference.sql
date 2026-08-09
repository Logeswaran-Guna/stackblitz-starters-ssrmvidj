-- Adds a narrower "time preference" question that appears once a Schedule
-- preference is chosen (e.g. Weekday evenings -> 4-6PM/5-7PM/6-8PM/7-9PM/
-- Flexible; see TIME_PREFERENCES_BY_SCHEDULE in lib/categories.ts for the
-- full set). Added to both the parent side (requirements) and, newly, the
-- teacher side (teacher_profiles didn't have a schedule_pref field at all
-- before this) — the founder chose to add both fresh rather than repurpose
-- the existing, differently-shaped Availability multi-select.

alter table requirements add column if not exists time_preference text;
alter table teacher_profiles add column if not exists schedule_pref text;
alter table teacher_profiles add column if not exists time_preference text;

-- === Parent side: submit_requirement chain =================================
-- New trailing param with a default, so CREATE OR REPLACE can extend these
-- without a drop (same reasoning as p_image_url in 0024).

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
  p_prior_tutoring_experience text default null,
  p_time_preference text default null
)
returns requirements
language plpgsql security definer set search_path = public as $$
declare
  v_student students;
  v_req requirements;
  v_count int;
  v_best_score int;
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

  insert into requirements (display_id, parent_id, student_id, subject, mode, location, schedule_pref, time_preference, pricing_type, budget, preferred_teacher_gender)
  values (next_daily_id('requirement_daily', 'FMREQ'), p_parent_id, v_student.id, p_subject, p_mode, p_location, p_schedule_pref, p_time_preference, p_pricing_type, p_budget, p_preferred_teacher_gender)
  returning * into v_req;

  perform _notify('PARENT', p_parent_id, 'REQUIREMENT_SUBMITTED', 'Request received',
    'Your request for ' || p_subject || ' has been received (ID: ' || v_req.display_id || '). Our team will review it shortly.');

  -- === Simplified match-quality check, notification-only ===================
  select max(
    (case when exists (select 1 from unnest(t.subjects) s where s ilike '%' || p_subject || '%' or p_subject ilike '%' || s || '%') then 50 else 0 end)
    + (case when t.teaching_mode && p_mode then 25 else 10 end)
    + (case when p_location is null or p_location = '' or exists (select 1 from unnest(t.preferred_locations) l where l ilike '%' || p_location || '%' or p_location ilike '%' || l || '%') then 25 else 10 end)
  )
  into v_best_score
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where t.kyc_status = 'APPROVED' and u.status = 'ACTIVE';

  if coalesce(v_best_score, 0) < 40 then
    perform _notify('PARENT', p_parent_id, 'LOW_MATCH_AVAILABILITY',
      'We''re still working on your request',
      'We''re currently looking to fulfil your request for ' || p_subject || ', since tutor availability in your location doesn''t yet match what you''re looking for. We''ll get back to you as soon as possible — our executive will call you back. If you need further assistance, please reach us on WhatsApp or email (see the contact options in the footer).');
  end if;

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
  p_prior_tutoring_experience text default null,
  p_time_preference text default null
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
    p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience,
    p_time_preference
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
  p_prior_tutoring_experience text default null,
  p_time_preference text default null
)
returns requirements
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  return _submit_requirement_for(
    p_parent_id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget,
    p_preferred_teacher_gender, p_student_id, p_student_name, p_age_grade, p_age, p_gender,
    p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience,
    p_time_preference
  );
end;
$$;

-- === Teacher side: upsert_teacher_profile chain =============================

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
  p_boards text[] default null,
  p_bank_ifsc text default null,
  p_bank_holder_name text default null,
  p_bank_branch text default null,
  p_schedule_pref text default null,
  p_time_preference text default null
)
returns teacher_profiles
language plpgsql security definer set search_path = public as $$
declare
  v_profile teacher_profiles;
  v_availability text[] := coalesce(p_availability, case when p_time_slot is not null then array[p_time_slot] else '{}'::text[] end);
  v_bank_upi_ref text := encrypt_secret(p_bank_upi_ref);
begin
  select * into v_profile from teacher_profiles where user_id = p_user_id;

  if v_profile.id is null then
    insert into teacher_profiles (display_id, user_id, qualification, experience, subjects, preferred_locations, teaching_mode, availability, rate_expectation, bank_upi_ref, address, area_city, pincode, whatsapp, kyc_status, photo_url, tutoring_for, boards, bank_ifsc, bank_holder_name, bank_branch, schedule_pref, time_preference)
    values (p_display_id, p_user_id, p_qualification, p_experience, coalesce(p_subjects, '{}'), coalesce(p_preferred_locations, '{}'), coalesce(p_teaching_mode, '{}'), v_availability, p_rate_expectation, v_bank_upi_ref, p_address, p_area_city, p_pincode, p_whatsapp, 'PENDING', p_photo_url, coalesce(p_tutoring_for, '{}'), coalesce(p_boards, '{}'), p_bank_ifsc, p_bank_holder_name, p_bank_branch, p_schedule_pref, p_time_preference)
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
      bank_upi_ref = coalesce(v_bank_upi_ref, bank_upi_ref),
      address = coalesce(p_address, address),
      area_city = coalesce(p_area_city, area_city),
      pincode = coalesce(p_pincode, pincode),
      whatsapp = coalesce(p_whatsapp, whatsapp),
      photo_url = coalesce(p_photo_url, photo_url),
      tutoring_for = case when p_tutoring_for is not null and array_length(p_tutoring_for, 1) > 0 then p_tutoring_for else tutoring_for end,
      boards = case when p_boards is not null and array_length(p_boards, 1) > 0 then p_boards else boards end,
      bank_ifsc = coalesce(p_bank_ifsc, bank_ifsc),
      bank_holder_name = coalesce(p_bank_holder_name, bank_holder_name),
      bank_branch = coalesce(p_bank_branch, bank_branch),
      schedule_pref = coalesce(p_schedule_pref, schedule_pref),
      time_preference = coalesce(p_time_preference, time_preference)
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
  p_boards text[] default null,
  p_bank_ifsc text default null,
  p_bank_holder_name text default null,
  p_bank_branch text default null,
  p_schedule_pref text default null,
  p_time_preference text default null
)
returns teacher_profiles
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;
  return _upsert_teacher_profile_for(
    me.id, me.display_id, p_qualification, p_experience, p_subjects, p_preferred_locations,
    p_teaching_mode, p_availability, p_time_slot, p_rate_expectation, p_bank_upi_ref,
    p_address, p_area_city, p_pincode, p_whatsapp, p_photo_url, p_tutoring_for, p_boards,
    p_bank_ifsc, p_bank_holder_name, p_bank_branch, p_schedule_pref, p_time_preference
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
  p_boards text[] default null,
  p_bank_ifsc text default null,
  p_bank_holder_name text default null,
  p_bank_branch text default null,
  p_schedule_pref text default null,
  p_time_preference text default null
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
    p_address, p_area_city, p_pincode, p_whatsapp, p_photo_url, p_tutoring_for, p_boards,
    p_bank_ifsc, p_bank_holder_name, p_bank_branch, p_schedule_pref, p_time_preference
  );
end;
$$;

-- === Read RPCs: RETURNS TABLE column list changing, drop first =============

drop function if exists my_requirements();

create or replace function my_requirements()
returns table (
  id uuid, display_id text, subject text, mode text[], location text,
  schedule_pref text, time_preference text, pricing_type text, budget numeric, status requirement_status,
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
    r.id, r.display_id, r.subject, r.mode, r.location, r.schedule_pref, r.time_preference, r.pricing_type, r.budget, r.status, r.created_at,
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

drop function if exists admin_requirements_queue();

create or replace function admin_requirements_queue()
returns table (
  id uuid, display_id text, subject text, mode text[], location text, schedule_pref text, time_preference text,
  budget numeric, preferred_teacher_gender text, status requirement_status, created_at timestamptz,
  parent_display_id text, parent_name text, parent_phone text,
  student_display_id text, student_name text, student_grade text,
  match_id uuid, match_label text, match_status match_status, match_score numeric,
  demo_date date, demo_time_slot text, parent_accepted_demo boolean, teacher_accepted_demo boolean,
  teacher_id uuid, teacher_display_id text, teacher_name text,
  parent_onetime_fee_amount numeric, parent_fee_collected boolean,
  referral_discount_amount numeric, referral_discount_code text
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
  select r.id, r.display_id, r.subject, r.mode, r.location, r.schedule_pref, r.time_preference, r.budget, r.preferred_teacher_gender, r.status, r.created_at,
    p.display_id, p.name, p.phone,
    s.display_id, s.student_name, s.age_grade,
    bm.id, case when bm.id is not null then match_display_id(bm) else null end, bm.status, bm.match_score,
    bm.demo_date, bm.demo_time_slot, bm.parent_accepted_demo, bm.teacher_accepted_demo,
    tp.id, tp.display_id, tu.name,
    bm.parent_onetime_fee_amount, bm.parent_onetime_fee_collected_at is not null,
    bm.referral_discount_amount, bm.referral_discount_code
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

drop function if exists my_teacher_profile();

create or replace function my_teacher_profile()
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], schedule_pref text, time_preference text, rate_expectation numeric, bank_upi_ref text,
  bank_ifsc text, bank_holder_name text, bank_branch text,
  address text, pincode text,
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
    t.subjects, t.preferred_locations, t.teaching_mode, t.availability, t.schedule_pref, t.time_preference, t.rate_expectation,
    decrypt_secret(t.bank_upi_ref), t.bank_ifsc, t.bank_holder_name, t.bank_branch,
    t.address, t.pincode,
    t.kyc_status, t.kyc_document_path, t.photo_url,
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

drop function if exists admin_teachers_directory(text);

create or replace function admin_teachers_directory(p_subject text default null)
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], schedule_pref text, time_preference text, rate_expectation numeric,
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
  perform _recompute_all_statuses();

  return query
  select t.id, t.display_id, u.name, u.phone, u.email, t.qualification, t.experience,
    t.subjects, t.preferred_locations, t.teaching_mode, t.availability, t.schedule_pref, t.time_preference, t.rate_expectation,
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

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
