-- Adds the one-time parent-side platform fee for standard (non-pooled)
-- matches, per founder decision: once a parent approves a tutor (match
-- goes CONFIRMED), they owe Future Minds a one-time 20% of the requirement's
-- budget — separate from the teacher's own recurring 10% commission, which
-- is already handled by the existing (repeatable) release_payout flow and
-- needs no schema change: admin just releases it again each month for as
-- long as the batch stays active.
--
-- Community Pooling is unaffected by this migration — its parent-side 10%
-- stays the existing per-household pool_amount/collected flag from 0021,
-- now understood as a recurring-monthly charge that admin manually
-- re-collects (toggles) each month, not a one-time amount.
--
-- No payment gateway exists, so — like every other fee in this system —
-- this is tracked, not collected in-app: admin marks it collected once the
-- money actually changes hands.

alter table matches add column if not exists parent_onetime_fee_amount numeric;
alter table matches add column if not exists parent_onetime_fee_collected_at timestamptz;

-- === Parent approves a tutor: auto-computes the one-time fee =============
create or replace function approve_teacher(p_match_id text)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_req requirements;
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

  -- Only standard matches get the one-time fee — pooled matches use the
  -- separate recurring-monthly parent surcharge from 0021 instead.
  if v_match.pooling_group_id is null and v_req.budget is not null then
    v_fee := round(v_req.budget * 0.20);
  end if;

  update matches
  set status = 'CONFIRMED', parent_approved_at = now(), parent_onetime_fee_amount = v_fee
  where id = v_match.id
  returning * into v_match;

  update requirements set status = 'assigned' where id = v_req.id;

  return v_match;
end;
$$;

-- === Admin: correct the one-time fee amount (e.g. budget didn't reflect
-- the final agreed price) ==================================================
create or replace function set_parent_onetime_fee(p_match_id text, p_amount numeric)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;

  update matches set parent_onetime_fee_amount = p_amount where id = v_match.id returning * into v_match;
  return v_match;
end;
$$;

-- === Admin: mark the one-time fee collected (or undo) ====================
create or replace function set_parent_fee_collected(p_match_id text, p_collected boolean)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;

  update matches
  set parent_onetime_fee_collected_at = case when p_collected then now() else null end
  where id = v_match.id
  returning * into v_match;

  return v_match;
end;
$$;

-- === Admin requirements queue: surface the fee alongside the match =======
-- RETURNS TABLE column set is changing, so CREATE OR REPLACE alone won't
-- work — Postgres requires the old signature to be dropped first.
drop function if exists admin_requirements_queue();

create or replace function admin_requirements_queue()
returns table (
  id uuid, display_id text, subject text, mode text[], location text, schedule_pref text,
  budget numeric, preferred_teacher_gender text, status requirement_status, created_at timestamptz,
  parent_display_id text, parent_name text, parent_phone text,
  student_display_id text, student_name text, student_grade text,
  match_id uuid, match_label text, match_status match_status, match_score numeric,
  demo_date date, demo_time_slot text, parent_accepted_demo boolean, teacher_accepted_demo boolean,
  teacher_id uuid, teacher_display_id text, teacher_name text,
  parent_onetime_fee_amount numeric, parent_fee_collected boolean
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
    tp.id, tp.display_id, tu.name,
    bm.parent_onetime_fee_amount, bm.parent_onetime_fee_collected_at is not null
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

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
