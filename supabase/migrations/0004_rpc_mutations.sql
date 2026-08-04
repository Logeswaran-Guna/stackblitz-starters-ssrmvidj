-- Every mutating endpoint from the Express prototype, ported 1:1 as a
-- SECURITY DEFINER Postgres function. The frontend calls these via
-- supabase.rpc('function_name', {...}) instead of POST/PUT REST calls.
-- Table grants (0006) block direct INSERT/UPDATE/DELETE, so these
-- functions are the *only* way to mutate business data — same effect as
-- "only the Express routes can touch the JSON file."

create or replace function current_profile()
returns profiles language sql stable as $$
  select * from profiles where id = auth.uid();
$$;

-- === shared logic behind submit_requirement, used both by a parent acting
-- === for themselves and by admin_register_parent_requirement acting on a
-- === caller's behalf. Not exposed directly (no role check of its own —
-- === callers are responsible for authorizing p_parent_id).
create or replace function _submit_requirement_for(
  p_parent_id uuid,
  p_subject text,
  p_mode text[],
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

-- === admin: submits a requirement on behalf of a parent an executive is
-- === registering over the phone (e.g. an on-call assist). The parent
-- === account itself must already exist (created via the admin API route
-- === using the service-role key before this is called).
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

-- === shared logic behind upsert_teacher_profile, used both by a teacher
-- === acting for themselves and by admin_register_teacher_profile acting
-- === on a caller's behalf. Not exposed directly.
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

-- === teachers.js: PUT /teachers/me =========================================
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

-- === admin: creates/updates a tutor application on behalf of a caller an
-- === executive is registering. The teacher account itself must already
-- === exist (created via the admin API route using the service-role key
-- === before this is called).
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

-- === matches.js: POST /matches =============================================
create or replace function create_match(p_requirement_id text, p_teacher_id text, p_match_score numeric default null)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_req requirements;
  v_teacher teacher_profiles;
  v_seq record;
  v_match matches;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  v_req := find_requirement(p_requirement_id);
  if v_req.id is null then raise exception 'Requirement not found'; end if;
  v_teacher := find_teacher(p_teacher_id);
  if v_teacher.id is null then raise exception 'Teacher profile not found'; end if;

  select * into v_seq from next_match_seq();

  insert into matches (id_year, id_seq, requirement_id, teacher_id, match_score, status)
  values (v_seq.id_year, v_seq.id_seq, v_req.id, v_teacher.id, p_match_score, 'PROPOSED')
  returning * into v_match;

  return v_match;
end;
$$;

-- === matches.js: PUT /matches/:id/propose-demo =============================
create or replace function propose_demo(p_match_id text, p_date date, p_time_slot text default null)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_clash matches;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  if p_date is null then raise exception 'date is required'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status <> 'PROPOSED' then
    raise exception 'Cannot propose a demo from status %', v_match.status;
  end if;

  if p_time_slot is not null then
    select * into v_clash from matches m
    where m.id <> v_match.id
      and m.teacher_id = v_match.teacher_id
      and m.status in ('DEMO_PROPOSED', 'DEMO_SCHEDULED', 'CONFIRMED')
      and m.demo_date = p_date
      and m.demo_time_slot = p_time_slot
    limit 1;

    if v_clash.id is not null then
      raise exception 'This teacher already has % booked on % in the "%" slot. Pick a different date/slot or a different teacher.',
        match_display_id(v_clash), p_date, p_time_slot;
    end if;
  end if;

  update matches set
    status = 'DEMO_PROPOSED',
    demo_date = p_date,
    demo_time_slot = p_time_slot,
    demo_proposed_at = now(),
    parent_accepted_demo = false,
    teacher_accepted_demo = false
  where id = v_match.id
  returning * into v_match;

  return v_match;
end;
$$;

-- === matches.js: PUT /matches/:id/accept-demo ===============================
create or replace function accept_demo(p_match_id text)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_req requirements;
  v_teacher teacher_profiles;
begin
  if me.role not in ('PARENT', 'TEACHER') then raise exception 'Not authorized'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status not in ('DEMO_PROPOSED', 'DEMO_SCHEDULED') then
    raise exception 'No demo awaiting response (status: %)', v_match.status;
  end if;

  if me.role = 'PARENT' then
    select r.* into v_req from requirements r where r.id = v_match.requirement_id;
    if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your requirement'; end if;
    update matches set parent_accepted_demo = true where id = v_match.id returning * into v_match;
  else
    select t.* into v_teacher from teacher_profiles t where t.user_id = me.id;
    if v_teacher.id is null or v_match.teacher_id <> v_teacher.id then raise exception 'Not your match'; end if;
    update matches set teacher_accepted_demo = true where id = v_match.id returning * into v_match;
  end if;

  if v_match.parent_accepted_demo and v_match.teacher_accepted_demo and v_match.status = 'DEMO_PROPOSED' then
    update matches set status = 'DEMO_SCHEDULED', scheduled_at = now() where id = v_match.id returning * into v_match;
  end if;

  return v_match;
end;
$$;

-- === matches.js: PUT /matches/:id/decline-demo ==============================
create or replace function decline_demo(p_match_id text, p_reason text default null)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_req requirements;
  v_teacher teacher_profiles;
  v_frozen text;
begin
  if me.role not in ('PARENT', 'TEACHER') then raise exception 'Not authorized'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status not in ('DEMO_PROPOSED', 'DEMO_SCHEDULED') then
    raise exception 'No demo awaiting response (status: %)', v_match.status;
  end if;

  if me.role = 'PARENT' then
    select r.* into v_req from requirements r where r.id = v_match.requirement_id;
    if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your requirement'; end if;
  else
    select t.* into v_teacher from teacher_profiles t where t.user_id = me.id;
    if v_teacher.id is null or v_match.teacher_id <> v_teacher.id then raise exception 'Not your match'; end if;
  end if;

  v_frozen := match_display_id(v_match); -- freeze BEFORE status flips, same as the original

  update matches set
    frozen_display_id = v_frozen,
    status = 'DECLINED',
    dead = true,
    declined_by = me.role::text,
    decline_reason = p_reason
  where id = v_match.id
  returning * into v_match;

  return v_match;
end;
$$;

-- === matches.js: PUT /matches/:id/approve-teacher ===========================
create or replace function approve_teacher(p_match_id text)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_req requirements;
begin
  if me.role <> 'PARENT' then raise exception 'Not authorized'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;

  select r.* into v_req from requirements r where r.id = v_match.requirement_id;
  if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your requirement'; end if;
  if v_match.status <> 'DEMO_SCHEDULED' then
    raise exception 'Cannot approve from status % — demo must be scheduled first', v_match.status;
  end if;

  update matches set status = 'CONFIRMED', parent_approved_at = now() where id = v_match.id returning * into v_match;
  update requirements set status = 'assigned' where id = v_req.id;

  return v_match;
end;
$$;

-- === attendance.js: POST /attendance/sessions ===============================
create or replace function log_session(p_match_id text, p_date date, p_time_slot text default null, p_amount numeric default null, p_duration_hours numeric default null)
returns class_sessions
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_teacher teacher_profiles;
  v_session class_sessions;
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;
  if p_match_id is null or p_date is null then raise exception 'matchId and date are required'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;

  select t.* into v_teacher from teacher_profiles t where t.user_id = me.id;
  if v_teacher.id is null or v_match.teacher_id <> v_teacher.id then raise exception 'Not your match'; end if;
  if v_match.status <> 'CONFIRMED' then
    raise exception 'Match must be CONFIRMED (an FMAPPROVED... ID) before logging classes';
  end if;

  insert into class_sessions (display_id, match_id, date, time_slot, amount, duration_hours)
  values (next_daily_id('attendance_daily', 'FMATTEND'), v_match.id, p_date, p_time_slot, p_amount, p_duration_hours)
  returning * into v_session;

  return v_session;
end;
$$;

-- === teacher dashboard: parent leaves a rating/review for a CONFIRMED assignment ===
-- One review per match; a parent re-submitting for the same match updates
-- their existing review rather than creating a duplicate.
create or replace function submit_teacher_review(p_match_id text, p_rating int, p_comment text default null)
returns teacher_reviews
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_req requirements;
  v_student students;
  v_review teacher_reviews;
begin
  if me.role <> 'PARENT' then raise exception 'Parent only'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'Rating must be between 1 and 5'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.status <> 'CONFIRMED' then raise exception 'You can only review a confirmed assignment'; end if;

  select r.* into v_req from requirements r where r.id = v_match.requirement_id;
  if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your assignment'; end if;

  select s.* into v_student from students s where s.id = v_req.student_id;

  insert into teacher_reviews (match_id, teacher_id, parent_id, student_name, rating, comment)
  values (v_match.id, v_match.teacher_id, me.id, v_student.student_name, p_rating, p_comment)
  on conflict (match_id) do update set
    rating = excluded.rating,
    comment = excluded.comment,
    created_at = now()
  returning * into v_review;

  return v_review;
end;
$$;

-- === teacher's own reviews (for the "Parent & student appreciation" section) ===
create or replace function my_teacher_reviews()
returns setof teacher_reviews
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_teacher teacher_profiles;
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;

  select * into v_teacher from teacher_profiles where user_id = me.id;
  if v_teacher.id is null then return; end if;

  return query select * from teacher_reviews where teacher_id = v_teacher.id order by created_at desc;
end;
$$;

-- === attendance.js: PUT /attendance/sessions/:id/confirm ====================
create or replace function confirm_session(p_session_id text)
returns class_sessions
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_session class_sessions;
  v_match matches;
  v_req requirements;
begin
  if me.role <> 'PARENT' then raise exception 'Parent only'; end if;

  v_session := find_session(p_session_id);
  if v_session.id is null then raise exception 'Session not found'; end if;

  select * into v_match from matches where id = v_session.match_id;
  select * into v_req from requirements where id = v_match.requirement_id;
  if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your class session'; end if;
  if v_session.status <> 'LOGGED' then raise exception 'Cannot confirm from status %', v_session.status; end if;

  update class_sessions set status = 'PARENT_CONFIRMED', parent_confirmed_at = now()
  where id = v_session.id returning * into v_session;

  return v_session;
end;
$$;

-- === attendance.js: PUT /attendance/sessions/:id/dispute ====================
create or replace function dispute_session(p_session_id text, p_reason text default null)
returns class_sessions
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_session class_sessions;
  v_match matches;
  v_req requirements;
begin
  if me.role <> 'PARENT' then raise exception 'Parent only'; end if;

  v_session := find_session(p_session_id);
  if v_session.id is null then raise exception 'Session not found'; end if;

  select * into v_match from matches where id = v_session.match_id;
  select * into v_req from requirements where id = v_match.requirement_id;
  if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your class session'; end if;

  update class_sessions set status = 'DISPUTED', disputed_at = now(), dispute_reason = p_reason
  where id = v_session.id returning * into v_session;

  return v_session;
end;
$$;

-- === attendance.js: PUT /attendance/sessions/:id/validate ===================
create or replace function validate_session(p_session_id text)
returns class_sessions
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_session class_sessions;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  v_session := find_session(p_session_id);
  if v_session.id is null then raise exception 'Session not found'; end if;
  if v_session.status <> 'PARENT_CONFIRMED' then
    raise exception 'Session must be PARENT_CONFIRMED before admin validation';
  end if;

  update class_sessions set status = 'ADMIN_VALIDATED', admin_validated_at = now()
  where id = v_session.id returning * into v_session;

  return v_session;
end;
$$;

-- === attendance.js: POST /attendance/payouts =================================
create or replace function release_payout(
  p_teacher_id text default null,
  p_match_id text default null,     -- pass instead of teacher_id; teacher is resolved from the match
  p_period text default null,
  p_commission_percent numeric default 0
)
returns payouts
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_teacher teacher_profiles;
  v_match matches;
  v_gross numeric;
  v_commission numeric;
  v_payout payouts;
  v_session_ids uuid[];
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  if p_teacher_id is null and p_match_id is not null then
    v_match := find_match(p_match_id);
    if v_match.id is null then raise exception 'Match not found for that ID'; end if;
    p_teacher_id := v_match.teacher_id::text;
  end if;
  if p_teacher_id is null then
    raise exception 'Provide teacherId, or a matchId (FMAPPROVED...) to resolve it automatically';
  end if;

  v_teacher := find_teacher(p_teacher_id);
  if v_teacher.id is null then raise exception 'Teacher profile not found'; end if;
  if v_teacher.bank_upi_ref is null then
    raise exception 'Teacher has no bank/UPI details on file — cannot release payout until they add one';
  end if;

  select array_agg(s.id), coalesce(sum(s.amount), 0)
  into v_session_ids, v_gross
  from class_sessions s
  join matches m on m.id = s.match_id
  where m.teacher_id = v_teacher.id and s.status = 'ADMIN_VALIDATED' and s.payout_id is null;

  if v_session_ids is null or array_length(v_session_ids, 1) is null then
    raise exception 'No validated, unpaid sessions for this teacher';
  end if;

  v_commission := round(v_gross * (p_commission_percent / 100));

  insert into payouts (teacher_id, period, gross_amount, commission_percent, commission_deducted, amount, bank_upi_ref, status, released_at)
  values (v_teacher.id, p_period, v_gross, p_commission_percent, v_commission, v_gross - v_commission, v_teacher.bank_upi_ref, 'RELEASED', now())
  returning * into v_payout;

  update class_sessions set payout_id = v_payout.id where id = any(v_session_ids);

  return v_payout;
end;
$$;

-- === KYC: teacher records where their uploaded ID document landed =========
-- Called right after a successful upload to the private kyc-documents
-- storage bucket (see 0007_kyc_storage.sql). Resets status to PENDING so a
-- re-upload (e.g. after a rejection) goes back through admin review.
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

-- === KYC: admin approves or rejects a teacher's submitted ID document =====
create or replace function set_teacher_kyc_status(p_teacher_id text, p_status text)
returns teacher_profiles
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_teacher teacher_profiles;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  if p_status not in ('APPROVED', 'REJECTED', 'PENDING') then
    raise exception 'Status must be APPROVED, REJECTED, or PENDING';
  end if;

  v_teacher := find_teacher(p_teacher_id);
  if v_teacher.id is null then raise exception 'Teacher profile not found'; end if;

  update teacher_profiles set kyc_status = p_status where id = v_teacher.id returning * into v_teacher;
  return v_teacher;
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

-- === admin: Manage Users — set a parent or teacher's status ================
-- Any status change on a PARENT cascades to their students (the family's
-- whole record moves together, in either direction — removing OR
-- restoring); a TEACHER only affects that one profile. Nothing is ever
-- hard-deleted — DELETED is itself just a status, so history/matches/
-- payouts stay intact for accounting and dispute purposes.
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

  if v_target.role = 'PARENT' then
    update students set status = p_status where parent_id = v_target.id;
  end if;

  return v_target;
end;
$$;

-- === admin: Manage Users — set a single student's status ===================
-- Never touches the parent's own status — removing one child's record
-- doesn't affect the rest of the family's account.
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

-- === automatic Active/Idle status ============================================
-- REMOVED/DELETED are exclusively admin actions and are never touched here.
-- For everyone else: an ongoing (CONFIRMED) assignment always means ACTIVE;
-- otherwise, no sign-in activity for 3+ months means IDLE, and anything
-- more recent means ACTIVE. Called as a side effect of the RPCs a
-- parent/teacher's own dashboard already loads (self-heals their own
-- status on every visit) and of the admin directory RPCs (self-heals
-- everyone whenever Manage Users is opened) — no cron job needed.
create or replace function _recompute_status(p_profile_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role user_role;
  v_current entity_status;
  v_has_active boolean;
  v_last_activity timestamptz;
begin
  select role, status into v_role, v_current from profiles where id = p_profile_id;
  if v_current is null or v_current in ('REMOVED', 'DELETED') then
    return;
  end if;

  if v_role = 'PARENT' then
    select exists(
      select 1 from matches m
      join requirements r on r.id = m.requirement_id
      where r.parent_id = p_profile_id and m.status = 'CONFIRMED'
    ) into v_has_active;
  elsif v_role = 'TEACHER' then
    select exists(
      select 1 from matches m
      join teacher_profiles t on t.id = m.teacher_id
      where t.user_id = p_profile_id and m.status = 'CONFIRMED'
    ) into v_has_active;
  else
    return; -- admin accounts aren't tracked this way
  end if;

  if v_has_active then
    update profiles set status = 'ACTIVE' where id = p_profile_id and status <> 'ACTIVE';
    return;
  end if;

  select greatest(coalesce(au.last_sign_in_at, p.created_at), p.created_at)
  into v_last_activity
  from profiles p
  join auth.users au on au.id = p.id
  where p.id = p_profile_id;

  if v_last_activity < now() - interval '3 months' then
    update profiles set status = 'IDLE' where id = p_profile_id and status = 'ACTIVE';
  else
    update profiles set status = 'ACTIVE' where id = p_profile_id and status = 'IDLE';
  end if;
end;
$$;

-- Bulk sweep used by the admin directory RPCs so Manage Users always shows
-- freshly self-healed statuses, not whatever was last computed.
create or replace function _recompute_all_statuses()
returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  for v_id in select id from profiles where role in ('PARENT', 'TEACHER') and status in ('ACTIVE', 'IDLE') loop
    perform _recompute_status(v_id);
  end loop;
end;
$$;
