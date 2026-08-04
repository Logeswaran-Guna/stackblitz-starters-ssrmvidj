-- Read-side RPCs mirroring each GET route's role-scoped, joined output.
-- These exist because RLS alone can't cheaply express "a parent may see the
-- NAME of the teacher matched to their own requirement" without opening up
-- broad cross-role SELECT policies on profiles/teacher_profiles. Each
-- function is SECURITY DEFINER and scopes everything to auth.uid() itself.

-- === public landing page: real, non-fabricated hero stats ===================
-- Callable while signed out (see the explicit anon grant in 0006) — only
-- returns aggregate counts, nothing identifying. "Onboarded" tutors means
-- KYC-approved specifically, not just registered, so the number reflects
-- vetted educators rather than raw signups.
create or replace function public_landing_stats()
returns table (tutors_onboarded int, classes_completed int)
language sql security definer set search_path = public as $$
  select
    (select count(*) from teacher_profiles where kyc_status = 'APPROVED')::int,
    (select count(*) from class_sessions where status in ('PARENT_CONFIRMED', 'ADMIN_VALIDATED'))::int;
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

-- === requirements.js: GET /requirements/my-students ==========================
create or replace function my_students()
returns setof students
language sql security definer set search_path = public as $$
  select * from students where parent_id = auth.uid() order by created_at desc;
$$;

-- === requirements.js: GET /requirements (admin queue) ========================
-- Includes the best current match (if any) so the admin UI can show status
-- and decide whether to offer "create match" vs "propose demo" actions,
-- mirroring my_requirements()'s "prefer CONFIRMED, else most recent
-- non-DECLINED" selection logic.
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

-- === admin: Manage Users — every parent, with their students nested =======
create or replace function admin_parents_directory()
returns table (
  id uuid, display_id text, name text, phone text, email text,
  status entity_status, created_at timestamptz, students jsonb
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  perform _recompute_all_statuses();

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

-- === teacher's own full profile (for the editable Teacher Profile page) ===
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

-- === admin: full logged-classes list with student/teacher names ============
-- Mirrors the teacher's own "My Logged Classes" table, enriched with parent/
-- teacher/student identity since admin oversees every teacher at once.
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

-- === matches.js: GET /matches?requirementId=... ==============================
-- Includes requirement/student/parent details so a teacher viewing their
-- own matches (or a parent viewing theirs) sees who they're matched with,
-- not just the raw match row.
create or replace function my_matches(p_requirement_id text default null)
returns table (
  id uuid, display_id text, requirement_id uuid, teacher_id uuid, match_score numeric,
  status match_status, demo_date date, demo_time_slot text, parent_accepted_demo boolean,
  teacher_accepted_demo boolean, scheduled_at timestamptz, declined_by text, decline_reason text,
  parent_approved_at timestamptz, created_at timestamptz, teacher_name text, teacher_subjects text[],
  subject text, location text, schedule_pref text,
  student_name text, student_grade text, parent_name text, parent_phone text
)
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_req_uuid uuid;
begin
  if p_requirement_id is not null then
    v_req_uuid := (find_requirement(p_requirement_id)).id;
  end if;

  return query
  select m.id, match_display_id(m), m.requirement_id, m.teacher_id, m.match_score, m.status,
    m.demo_date, m.demo_time_slot, m.parent_accepted_demo, m.teacher_accepted_demo,
    m.scheduled_at, m.declined_by, m.decline_reason, m.parent_approved_at, m.created_at,
    tu.name, tp.subjects,
    r.subject, r.location, r.schedule_pref,
    s.student_name, s.age_grade, pu.name, pu.phone
  from matches m
  join teacher_profiles tp on tp.id = m.teacher_id
  join profiles tu on tu.id = tp.user_id
  join requirements r on r.id = m.requirement_id
  join profiles pu on pu.id = r.parent_id
  left join students s on s.id = r.student_id
  where (p_requirement_id is null or m.requirement_id = v_req_uuid)
    and (
      me.role = 'ADMIN'
      or (me.role = 'PARENT' and m.requirement_id in (select r2.id from requirements r2 where r2.parent_id = me.id))
      or (me.role = 'TEACHER' and m.teacher_id = (select t.id from teacher_profiles t where t.user_id = me.id))
    )
  order by m.created_at desc;
end;
$$;

-- === attendance.js: GET /attendance/sessions?matchId=&status= ================
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

-- === attendance.js: GET /attendance/payouts ===================================
create or replace function my_payouts()
returns setof payouts
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role = 'ADMIN' then
    return query select * from payouts order by released_at desc;
  elsif me.role = 'TEACHER' then
    return query select p.* from payouts p
      where p.teacher_id = (select t.id from teacher_profiles t where t.user_id = me.id)
      order by p.released_at desc;
  else
    raise exception 'Not authorized';
  end if;
end;
$$;

-- === assignments.js: GET /assignments =========================================
create or replace function my_assignments()
returns table (
  id uuid, display_id text, student_name text, class text, subject text, address text,
  area_city text, time_slot text, fees numeric, teacher_name text, teacher_display_id text,
  parent_approved_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  return query
  select
    m.id, match_display_id(m),
    coalesce(s.student_name, '—'), coalesce(s.age_grade, '—'), coalesce(r.subject, '—'),
    coalesce(s.address, r.location, tp.address, '—'), coalesce(s.area_city, tp.area_city, '—'),
    coalesce(m.demo_time_slot, r.schedule_pref, '—'), r.budget,
    coalesce(tu.name, '—'), tp.display_id, m.parent_approved_at
  from matches m
  join requirements r on r.id = m.requirement_id
  left join students s on s.id = r.student_id
  join teacher_profiles tp on tp.id = m.teacher_id
  join profiles tu on tu.id = tp.user_id
  where m.status = 'CONFIRMED'
    and (
      me.role = 'ADMIN'
      or (me.role = 'PARENT' and r.parent_id = me.id)
      or (me.role = 'TEACHER' and tp.user_id = me.id)
    )
  order by m.parent_approved_at desc;
end;
$$;
