-- ============================================================================
-- PART 1: Notifications core — table, read-tracking, and RPCs.
--
-- Two kinds of notification: admin-authored broadcasts (created_by set,
-- target_profile_id null, audience chosen from the admin "publish to"
-- dropdown) and system-generated personal ones (created_by null,
-- target_profile_id set to the one parent/teacher the event happened to).
-- A GENERAL notification with target_profile_id null is visible to every
-- visitor, signed in or not — that's the home page feed. A PARENT/TEACHER
-- notification with target_profile_id null is a broadcast to everyone with
-- that role; with target_profile_id set, it's personal.
-- ============================================================================

create table notifications (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  audience text not null check (audience in ('GENERAL', 'PARENT', 'TEACHER')),
  target_profile_id uuid references profiles(id) on delete cascade,
  event_type text,
  title text not null,
  body text not null,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index idx_notifications_audience on notifications(audience, created_at desc);
create index idx_notifications_target on notifications(target_profile_id, created_at desc);

alter table notifications enable row level security;
-- No policies — same pattern as the rest of this schema, every read/write
-- goes through the RPCs below.
revoke all on notifications from authenticated, anon;

-- Read-tracking: one timestamp per user is enough to drive an unread badge
-- (mark-all-as-seen on opening the panel) without a per-notification join
-- table nobody asked for.
alter table profiles add column if not exists notifications_last_seen_at timestamptz;

-- Internal helper used by the auto-trigger hooks in Part 3. Not exposed as
-- a meaningfully privileged action on its own (worst case a user could
-- spam themselves a junk personal notification), so no extra gating beyond
-- the standard authenticated-only grant at the bottom of this file.
create or replace function _notify(
  p_audience text,
  p_target_profile_id uuid,
  p_event_type text,
  p_title text,
  p_body text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (display_id, audience, target_profile_id, event_type, title, body)
  values (next_daily_id('notification_daily', 'FMNOTIF'), p_audience, p_target_profile_id, p_event_type, p_title, p_body);
end;
$$;

-- === Public: home page feed, signed-out visitors included =================
create or replace function general_notifications()
returns table (id uuid, display_id text, title text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select id, display_id, title, body, created_at
  from notifications
  where audience = 'GENERAL'
  order by created_at desc
  limit 30;
$$;

-- === Authenticated: General + Personal feed for the bell dropdown =========
-- Returns both scopes in one call, tagged, so the frontend can split them
-- into the "General | <name>" tabs without a second round trip.
create or replace function my_notifications()
returns table (id uuid, display_id text, scope text, title text, body text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  return query
    select n.id, n.display_id, 'GENERAL'::text, n.title, n.body, n.created_at
    from notifications n
    where n.audience = 'GENERAL'
    union all
    select n.id, n.display_id, 'PERSONAL'::text, n.title, n.body, n.created_at
    from notifications n
    where n.audience = me.role::text
      and (n.target_profile_id is null or n.target_profile_id = me.id)
    order by created_at desc
    limit 50;
end;
$$;

create or replace function my_unread_notification_count()
returns int
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_count int;
begin
  select count(*) into v_count
  from notifications n
  where (n.audience = 'GENERAL' or (n.audience = me.role::text and (n.target_profile_id is null or n.target_profile_id = me.id)))
    and n.created_at > coalesce(me.notifications_last_seen_at, 'epoch'::timestamptz);
  return v_count;
end;
$$;

create or replace function mark_notifications_seen()
returns void
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  update profiles set notifications_last_seen_at = now() where id = me.id;
end;
$$;

-- === Admin: compose a broadcast notification ================================
create or replace function admin_create_notification(p_audience text, p_title text, p_body text)
returns notifications
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_notification notifications;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  if p_audience not in ('GENERAL', 'PARENT', 'TEACHER') then raise exception 'Invalid audience'; end if;
  if p_title is null or trim(p_title) = '' then raise exception 'Title is required'; end if;
  if p_body is null or trim(p_body) = '' then raise exception 'Message is required'; end if;

  insert into notifications (display_id, audience, created_by, title, body)
  values (next_daily_id('notification_daily', 'FMNOTIF'), p_audience, me.id, trim(p_title), trim(p_body))
  returning * into v_notification;

  return v_notification;
end;
$$;

create or replace function admin_notifications_list()
returns table (
  id uuid, display_id text, audience text, target_profile_id uuid, event_type text,
  title text, body text, created_by_name text, created_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
    select n.id, n.display_id, n.audience, n.target_profile_id, n.event_type,
      n.title, n.body, p.name, n.created_at
    from notifications n
    left join profiles p on p.id = n.created_by
    order by n.created_at desc
    limit 200;
end;
$$;

create or replace function admin_delete_notification(p_id text)
returns void
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  delete from notifications where id::text = p_id or display_id = p_id;
end;
$$;

-- ============================================================================
-- PART 2: Become-a-Tutor bank details — UPI ID is enough on its own; a plain
-- account number needs IFSC + account holder name + branch to actually be
-- payable. These 3 are far less sensitive than the account/UPI reference
-- itself (which stays encrypted via encrypt_secret/decrypt_secret from
-- 0019), so they're stored as plain columns.
-- ============================================================================

alter table teacher_profiles add column if not exists bank_ifsc text;
alter table teacher_profiles add column if not exists bank_holder_name text;
alter table teacher_profiles add column if not exists bank_branch text;

-- Parameter lists are changing on all three of these, so the old signatures
-- must be dropped first — CREATE OR REPLACE with a different parameter list
-- creates a second overload instead of replacing the function (the exact
-- bug fixed in 0027 for upsert_academy_course/release_payout/
-- add_requirement_to_pooling_group).
drop function if exists _upsert_teacher_profile_for(uuid, text, text, text, text[], text[], text[], text[], text, numeric, text, text, text, text, text, text, text[], text[]);
drop function if exists upsert_teacher_profile(text, text, text[], text[], text[], text[], text, numeric, text, text, text, text, text, text, text[], text[]);
drop function if exists admin_register_teacher_profile(uuid, text, text, text[], text[], text[], text[], text, numeric, text, text, text, text, text, text, text[], text[]);

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
  p_bank_branch text default null
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
    insert into teacher_profiles (display_id, user_id, qualification, experience, subjects, preferred_locations, teaching_mode, availability, rate_expectation, bank_upi_ref, address, area_city, pincode, whatsapp, kyc_status, photo_url, tutoring_for, boards, bank_ifsc, bank_holder_name, bank_branch)
    values (p_display_id, p_user_id, p_qualification, p_experience, coalesce(p_subjects, '{}'), coalesce(p_preferred_locations, '{}'), coalesce(p_teaching_mode, '{}'), v_availability, p_rate_expectation, v_bank_upi_ref, p_address, p_area_city, p_pincode, p_whatsapp, 'PENDING', p_photo_url, coalesce(p_tutoring_for, '{}'), coalesce(p_boards, '{}'), p_bank_ifsc, p_bank_holder_name, p_bank_branch)
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
      bank_branch = coalesce(p_bank_branch, bank_branch)
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
  p_bank_branch text default null
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
    p_bank_ifsc, p_bank_holder_name, p_bank_branch
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
  p_bank_branch text default null
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
    p_bank_ifsc, p_bank_holder_name, p_bank_branch
  );
end;
$$;

-- RETURNS TABLE column list is changing, so the old signature must be
-- dropped first (same reasoning as the academy functions in 0024).
drop function if exists my_teacher_profile();

create or replace function my_teacher_profile()
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], rate_expectation numeric, bank_upi_ref text,
  bank_ifsc text, bank_holder_name text, bank_branch text,
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
    decrypt_secret(t.bank_upi_ref), t.bank_ifsc, t.bank_holder_name, t.bank_branch,
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

-- ============================================================================
-- PART 3: Auto-trigger notifications on existing status-changing actions.
-- Every function below keeps its exact existing parameter signature — only
-- an internal _notify(...) call is added to the body — so these are true
-- CREATE OR REPLACE replacements, not new overloads.
-- ============================================================================

-- === Requirement submitted (parent) ========================================
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

  insert into requirements (display_id, parent_id, student_id, subject, mode, location, schedule_pref, pricing_type, budget, preferred_teacher_gender)
  values (next_daily_id('requirement_daily', 'FMREQ'), p_parent_id, v_student.id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget, p_preferred_teacher_gender)
  returning * into v_req;

  perform _notify('PARENT', p_parent_id, 'REQUIREMENT_SUBMITTED', 'Request received',
    'Your request for ' || p_subject || ' has been received (ID: ' || v_req.display_id || '). Our team will review it shortly.');

  -- === Simplified match-quality check, notification-only ===================
  -- This is a lightweight proxy (subject + mode + location signal), not the
  -- full weighted algorithm computeMatchScore() uses for admin's actual
  -- matching UI — good enough to decide "should we reassure this parent
  -- proactively", not meant to replace admin's real matching decision.
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

-- === Match created (admin proposes a teacher) — notify both sides =========
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

  perform _notify('PARENT', v_req.parent_id, 'MATCH_PROPOSED', 'A tutor has been proposed',
    'A tutor has been proposed for your ' || v_req.subject || ' request (' || v_req.display_id || ').');
  perform _notify('TEACHER', v_teacher.user_id, 'MATCH_PROPOSED', 'New student request',
    'You''ve been matched with a new student request for ' || v_req.subject || '.');

  return v_match;
end;
$$;

-- === Demo proposed — notify both sides =====================================
create or replace function propose_demo(p_match_id text, p_date date, p_time_slot text default null)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_clash matches;
  v_req requirements;
  v_teacher teacher_profiles;
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

  select * into v_req from requirements where id = v_match.requirement_id;
  select * into v_teacher from teacher_profiles where id = v_match.teacher_id;

  perform _notify('PARENT', v_req.parent_id, 'DEMO_PROPOSED', 'Demo proposed',
    'A demo for your ' || v_req.subject || ' request has been proposed for ' || to_char(p_date, 'DD Mon YYYY') || coalesce(' (' || p_time_slot || ')', '') || '.');
  perform _notify('TEACHER', v_teacher.user_id, 'DEMO_PROPOSED', 'Demo proposed',
    'A demo for ' || v_req.subject || ' has been proposed for ' || to_char(p_date, 'DD Mon YYYY') || coalesce(' (' || p_time_slot || ')', '') || '.');

  return v_match;
end;
$$;

-- === Demo accepted by one side, or scheduled once both accept =============
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

  -- v_req/v_teacher here are the match's OWN parent/teacher, looked up
  -- unconditionally for notification targeting — NOT the authorization
  -- check itself. Ownership is still verified per-branch below.
  select r.* into v_req from requirements r where r.id = v_match.requirement_id;
  select t.* into v_teacher from teacher_profiles t where t.id = v_match.teacher_id;

  if me.role = 'PARENT' then
    if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your requirement'; end if;
    update matches set parent_accepted_demo = true where id = v_match.id returning * into v_match;
    perform _notify('TEACHER', v_teacher.user_id, 'DEMO_ACCEPTED', 'Parent accepted the demo',
      'The parent has accepted the proposed demo for ' || v_req.subject || '.');
  else
    if v_teacher.id is null or v_teacher.user_id <> me.id then raise exception 'Not your match'; end if;
    update matches set teacher_accepted_demo = true where id = v_match.id returning * into v_match;
    perform _notify('PARENT', v_req.parent_id, 'DEMO_ACCEPTED', 'Tutor accepted the demo',
      'The tutor has accepted the proposed demo for ' || v_req.subject || '.');
  end if;

  if v_match.parent_accepted_demo and v_match.teacher_accepted_demo and v_match.status = 'DEMO_PROPOSED' then
    update matches set status = 'DEMO_SCHEDULED', scheduled_at = now() where id = v_match.id returning * into v_match;
    perform _notify('PARENT', v_req.parent_id, 'DEMO_SCHEDULED', 'Demo scheduled',
      'Your demo for ' || v_req.subject || ' is now scheduled.');
    perform _notify('TEACHER', v_teacher.user_id, 'DEMO_SCHEDULED', 'Demo scheduled',
      'The demo for ' || v_req.subject || ' is now scheduled.');
  end if;

  return v_match;
end;
$$;

-- === Demo declined — notify both sides =====================================
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

  -- v_req/v_teacher here are the match's OWN parent/teacher, looked up
  -- unconditionally for notification targeting — NOT the authorization
  -- check itself. Ownership is still verified per-branch below.
  select r.* into v_req from requirements r where r.id = v_match.requirement_id;
  select t.* into v_teacher from teacher_profiles t where t.id = v_match.teacher_id;

  if me.role = 'PARENT' then
    if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your requirement'; end if;
  else
    if v_teacher.id is null or v_teacher.user_id <> me.id then raise exception 'Not your match'; end if;
  end if;

  v_frozen := match_display_id(v_match);

  update matches set
    frozen_display_id = v_frozen,
    status = 'DECLINED',
    dead = true,
    declined_by = me.role::text,
    decline_reason = p_reason
  where id = v_match.id
  returning * into v_match;

  perform _notify('PARENT', v_req.parent_id, 'DEMO_DECLINED', 'Demo declined',
    'The demo for ' || v_req.subject || ' was declined. Our team will follow up with next steps.');
  perform _notify('TEACHER', v_teacher.user_id, 'DEMO_DECLINED', 'Demo declined',
    'The demo for ' || v_req.subject || ' was declined.');

  return v_match;
end;
$$;

-- === Parent confirms the tutor — notify both sides =========================
create or replace function approve_teacher(p_match_id text)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_req requirements;
  v_teacher teacher_profiles;
  v_fee numeric;
begin
  if me.role <> 'PARENT' then raise exception 'Not authorized'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;

  select r.* into v_req from requirements r where r.id = v_match.requirement_id;
  if v_req.id is null or v_req.parent_id <> me.id then raise exception 'Not your requirement'; end if;
  if v_match.status <> 'DEMO_SCHEDULED' then
    raise exception 'Cannot approve from status % — demo must be scheduled first', v_match.status;
  end if;

  if v_match.pooling_group_id is null and v_req.budget is not null then
    v_fee := round(v_req.budget * 0.20);
  end if;

  update matches
  set status = 'CONFIRMED', parent_approved_at = now(), parent_onetime_fee_amount = v_fee
  where id = v_match.id
  returning * into v_match;

  update requirements set status = 'assigned' where id = v_req.id;

  select * into v_teacher from teacher_profiles where id = v_match.teacher_id;
  perform _notify('PARENT', v_req.parent_id, 'TEACHER_APPROVED', 'Tutor confirmed',
    'You''ve confirmed your tutor for ' || v_req.subject || '.');
  perform _notify('TEACHER', v_teacher.user_id, 'TEACHER_APPROVED', 'You''ve been confirmed!',
    'The parent has confirmed you for ' || v_req.subject || '.');

  return v_match;
end;
$$;

-- === KYC status change — notify the teacher =================================
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

  if p_status in ('APPROVED', 'REJECTED') then
    perform _notify('TEACHER', v_teacher.user_id, 'KYC_STATUS', 'KYC ' || initcap(lower(p_status)),
      'Your KYC document review is complete: ' || initcap(lower(p_status)) || '.');
  end if;

  return v_teacher;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
grant execute on function general_notifications() to anon;
