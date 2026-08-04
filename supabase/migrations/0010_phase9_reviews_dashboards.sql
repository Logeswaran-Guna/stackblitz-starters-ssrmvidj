-- ============================================================
-- Future Minds — Phase 9 schema sync
--
-- Adds real hour-tracking + a parent review/rating system so the Teacher
-- Dashboard's stats (tutoring hours, students trained, active batches,
-- rating) and "Parent & student appreciation" quotes are wired to real
-- data, per developer requirements 4.4: "Dashboard shows hours, students,
-- and reviews... wired to real data instead of in-memory JS state." Also
-- adds an admin-side logged-classes view with student/teacher names.
--
-- Run this against future-minds-test AFTER 0009_phase8_sync.sql.
-- ============================================================

-- 1. class_sessions.duration_hours ------------------------------------------

alter table class_sessions add column if not exists duration_hours numeric;

-- 2. teacher_reviews table ---------------------------------------------------

create table if not exists teacher_reviews (
  id uuid primary key default gen_random_uuid(),
  match_id uuid unique not null references matches(id) on delete cascade,
  teacher_id uuid not null references teacher_profiles(id) on delete cascade,
  parent_id uuid not null references profiles(id) on delete cascade,
  student_name text,
  rating int not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

create index if not exists idx_teacher_reviews_teacher on teacher_reviews(teacher_id);

alter table teacher_reviews enable row level security;

drop policy if exists teacher_reviews_select on teacher_reviews;
create policy teacher_reviews_select on teacher_reviews for select
  using (
    is_admin()
    or teacher_id in (select id from teacher_profiles where user_id = auth.uid())
    or parent_id = auth.uid()
  );

revoke all on teacher_reviews from authenticated, anon;
grant select on teacher_reviews to authenticated;

-- 3. RPCs --------------------------------------------------------------------

drop function if exists log_session;
drop function if exists submit_teacher_review;
drop function if exists my_teacher_reviews;
drop function if exists my_teacher_profile;
drop function if exists admin_teachers_directory;
drop function if exists admin_sessions_queue;
drop function if exists my_sessions;

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

-- === teacher's own full profile (adds real stats) ==========================
create or replace function my_teacher_profile()
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], rate_expectation numeric, bank_upi_ref text,
  kyc_status text, kyc_document_path text, photo_url text,
  tutoring_for text[], boards text[], rating numeric,
  languages jsonb,
  total_hours numeric, students_trained int, active_batches int,
  rating_avg numeric, rating_count int
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
    ),
    coalesce((select sum(cs.duration_hours) from class_sessions cs join matches m on m.id = cs.match_id where m.teacher_id = t.id and cs.status <> 'DISPUTED'), 0),
    coalesce((select count(distinct r.student_id) from matches m join requirements r on r.id = m.requirement_id where m.teacher_id = t.id and m.status = 'CONFIRMED'), 0)::int,
    coalesce((select count(*) from matches m where m.teacher_id = t.id and m.status = 'CONFIRMED'), 0)::int,
    (select round(avg(tr.rating), 1) from teacher_reviews tr where tr.teacher_id = t.id),
    coalesce((select count(*) from teacher_reviews tr where tr.teacher_id = t.id), 0)::int
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where t.user_id = me.id;
end;
$$;

-- === teachers.js: GET /teachers (admin directory, ?subject=) — adds real stats ===
create or replace function admin_teachers_directory(p_subject text default null)
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], rate_expectation numeric,
  bank_upi_ref text, kyc_status text, kyc_document_path text, photo_url text,
  tutoring_for text[], boards text[], rating numeric,
  languages jsonb,
  total_hours numeric, students_trained int, active_batches int,
  rating_avg numeric, rating_count int
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
    coalesce((select count(*) from teacher_reviews tr where tr.teacher_id = t.id), 0)::int
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where p_subject is null or p_subject = any(t.subjects);
end;
$$;

-- === admin: full logged-classes list with student/teacher names ============
create or replace function admin_sessions_queue()
returns table (
  id uuid, display_id text, match_id uuid, match_label text, date date, time_slot text,
  duration_hours numeric, status session_status, amount numeric,
  student_name text, student_grade text, subject text,
  teacher_display_id text, teacher_name text, teacher_phone text,
  parent_name text, parent_phone text,
  payment_released boolean, payout_amount numeric, payout_commission_percent numeric
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
  select s.id, s.display_id, s.match_id, match_display_id(m), s.date, s.time_slot,
    s.duration_hours, s.status, s.amount,
    st.student_name, st.age_grade, r.subject,
    tp.display_id, tu.name, tu.phone,
    pu.name, pu.phone,
    (s.payout_id is not null), po.amount, po.commission_percent
  from class_sessions s
  join matches m on m.id = s.match_id
  join requirements r on r.id = m.requirement_id
  left join students st on st.id = r.student_id
  join profiles pu on pu.id = r.parent_id
  join teacher_profiles tp on tp.id = m.teacher_id
  join profiles tu on tu.id = tp.user_id
  left join payouts po on po.id = s.payout_id
  order by s.teacher_marked_at desc;
end;
$$;

-- === attendance.js: GET /attendance/sessions?matchId=&status= — adds duration_hours ===
create or replace function my_sessions(p_match_id text default null, p_status session_status default null)
returns table (
  id uuid, display_id text, match_id uuid, match_label text, date date, time_slot text,
  status session_status, amount numeric, teacher_marked_at timestamptz, parent_confirmed_at timestamptz,
  admin_validated_at timestamptz, parent_approval text, admin_approval text, payment_released boolean,
  payout_amount numeric, payout_commission_percent numeric, payout_released_at timestamptz,
  duration_hours numeric
)
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match_uuid uuid;
begin
  if p_match_id is not null then
    v_match_uuid := (find_match(p_match_id)).id;
  end if;

  return query
  select
    s.id, s.display_id, s.match_id, match_display_id(m), s.date, s.time_slot, s.status, s.amount,
    s.teacher_marked_at, s.parent_confirmed_at, s.admin_validated_at,
    case s.status when 'LOGGED' then 'PENDING' when 'DISPUTED' then 'DISPUTED' else 'APPROVED' end,
    case s.status when 'ADMIN_VALIDATED' then 'APPROVED' else 'PENDING' end,
    (s.payout_id is not null),
    po.amount, po.commission_percent, po.released_at,
    s.duration_hours
  from class_sessions s
  join matches m on m.id = s.match_id
  left join payouts po on po.id = s.payout_id
  where (p_match_id is null or s.match_id = v_match_uuid)
    and (p_status is null or s.status = p_status)
    and (
      me.role = 'ADMIN'
      or (me.role = 'PARENT' and m.requirement_id in (select r.id from requirements r where r.parent_id = me.id))
      or (me.role = 'TEACHER' and m.teacher_id = (select t.id from teacher_profiles t where t.user_id = me.id))
    )
  order by s.teacher_marked_at desc;
end;
$$;

-- 4. Re-apply function grants -------------------------------------------------

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
