-- ============================================================
-- Future Minds — Phase 11 schema sync
--
-- Automatic Active/Idle status, self-healing on read (no cron needed):
-- an ongoing (CONFIRMED) assignment always means ACTIVE; otherwise no
-- sign-in activity for 3+ months means IDLE, anything more recent means
-- ACTIVE. REMOVED/DELETED are exclusively admin actions via Manage Users
-- and are never touched by this logic. Runs as a side effect of
-- my_requirements() (parent's own dashboard), my_teacher_profile()
-- (teacher's own profile — also now returns their status), and the admin
-- directory RPCs (recomputes everyone whenever Manage Users is opened).
--
-- Run this against future-minds-test AFTER 0011_phase10_status_and_admin_registration.sql.
-- ============================================================

drop function if exists _recompute_status;
drop function if exists _recompute_all_statuses;
drop function if exists my_requirements;
drop function if exists my_teacher_profile;
drop function if exists admin_teachers_directory;
drop function if exists admin_parents_directory;

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
    return;
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

-- === requirements.js: GET /requirements/mine — self-heals the parent's own status ===
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

-- === teacher's own full profile — self-heals status, now returns it ========
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

-- === admin directory RPCs — sweep-recompute everyone before listing ========
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

-- Re-apply function grants -------------------------------------------------

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
