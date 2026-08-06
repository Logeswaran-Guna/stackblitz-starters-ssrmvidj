-- Community Pooling backend. Per the founder's call, pooling has no
-- self-serve booking flow — parents just pick "Community Pooling" as a
-- requirement mode (existing `requirements.mode`), and the admin manually
-- groups nearby households onto one teacher/batch from the admin
-- dashboard. This adds the group entity, tags matches with the group they
-- belong to, and adds the tiered FM-share bands from Business Case §4.1.3
-- (20% / 30% / 40%, based on the pooled batch's gross payout) as a
-- suggestion the admin can accept or override when releasing a payout.
--
-- The ≤ Rs 10,000 baseline is explicitly left unset — the Business Case
-- itself flags that band as an open item for the founder to finalize.

create table pooling_groups (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  subject text not null,
  location text,
  status text not null default 'FORMING' check (status in ('FORMING', 'ACTIVE', 'CLOSED')),
  teacher_id uuid references teacher_profiles(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

-- Tags which pooled batch a match belongs to. Null for every ordinary
-- (non-pooled) match — this is additive, not a parallel matches table.
alter table matches add column pooling_group_id uuid references pooling_groups(id) on delete set null;
create index idx_matches_pooling_group on matches(pooling_group_id);

alter table pooling_groups enable row level security;

create policy pooling_groups_select on pooling_groups for select
  using (
    is_admin()
    or teacher_id in (select id from teacher_profiles where user_id = auth.uid())
    or id in (
      select m.pooling_group_id from matches m
      join requirements r on r.id = m.requirement_id
      where r.parent_id = auth.uid() and m.pooling_group_id is not null
    )
  );

revoke all on pooling_groups from authenticated, anon;
grant select on pooling_groups to authenticated;

-- === Admin: create a pooling group ==========================================
create or replace function create_pooling_group(p_subject text, p_location text default null, p_notes text default null)
returns pooling_groups
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_group pooling_groups;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  if p_subject is null or trim(p_subject) = '' then raise exception 'Subject is required'; end if;

  insert into pooling_groups (display_id, subject, location, notes)
  values (next_daily_id('pooling_daily', 'FMPOOL'), trim(p_subject), p_location, p_notes)
  returning * into v_group;

  return v_group;
end;
$$;

-- === Admin: assign (or change) the teacher running a pooled batch ==========
create or replace function assign_pooling_teacher(p_group_id text, p_teacher_id text)
returns pooling_groups
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_group pooling_groups;
  v_teacher teacher_profiles;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  select * into v_group from pooling_groups where id::text = p_group_id or display_id = p_group_id;
  if v_group.id is null then raise exception 'Pooling group not found'; end if;

  v_teacher := find_teacher(p_teacher_id);
  if v_teacher.id is null then raise exception 'Teacher profile not found'; end if;

  update pooling_groups
  set teacher_id = v_teacher.id, status = 'ACTIVE'
  where id = v_group.id
  returning * into v_group;

  return v_group;
end;
$$;

-- === Admin: add one household's requirement into a pooled batch ============
-- Reuses create_match so attendance/payout/review flows all work exactly
-- as they already do for a regular one-to-one match; this just tags the
-- resulting match with the group it belongs to.
create or replace function add_requirement_to_pooling_group(p_group_id text, p_requirement_id text)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_group pooling_groups;
  v_match matches;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  select * into v_group from pooling_groups where id::text = p_group_id or display_id = p_group_id;
  if v_group.id is null then raise exception 'Pooling group not found'; end if;
  if v_group.teacher_id is null then raise exception 'Assign a teacher to this pooling group first'; end if;

  v_match := create_match(p_requirement_id, v_group.teacher_id::text, null);
  update matches set pooling_group_id = v_group.id where id = v_match.id returning * into v_match;

  return v_match;
end;
$$;

-- === Admin: close a pooled batch (stops it accepting new members) ==========
create or replace function close_pooling_group(p_group_id text)
returns pooling_groups
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_group pooling_groups;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  update pooling_groups set status = 'CLOSED'
  where id::text = p_group_id or display_id = p_group_id
  returning * into v_group;

  if v_group.id is null then raise exception 'Pooling group not found'; end if;
  return v_group;
end;
$$;

-- === Tiered FM-share suggestion, Business Case §4.1.3 ========================
create or replace function pooling_suggested_commission_percent(p_gross numeric)
returns numeric
language sql immutable as $$
  select case
    when p_gross is null then null
    when p_gross <= 10000 then null   -- baseline not yet finalized by the founder
    when p_gross <= 15000 then 20
    when p_gross <= 20000 then 30
    else 40
  end;
$$;

-- === Admin: pooling groups overview, with live unpaid gross + suggested % ===
create or replace function admin_pooling_groups()
returns table (
  id uuid, display_id text, subject text, location text, status text, notes text, created_at timestamptz,
  teacher_id uuid, teacher_display_id text, teacher_name text,
  member_count bigint, unpaid_gross numeric, suggested_commission_percent numeric
)
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
    select
      pg.id, pg.display_id, pg.subject, pg.location, pg.status, pg.notes, pg.created_at,
      t.id, t.display_id, p.name,
      count(distinct m.id),
      coalesce(sum(cs.amount) filter (where cs.status = 'ADMIN_VALIDATED' and cs.payout_id is null), 0),
      pooling_suggested_commission_percent(
        coalesce(sum(cs.amount) filter (where cs.status = 'ADMIN_VALIDATED' and cs.payout_id is null), 0)
      )
    from pooling_groups pg
    left join teacher_profiles t on t.id = pg.teacher_id
    left join profiles p on p.id = t.user_id
    left join matches m on m.pooling_group_id = pg.id
    left join class_sessions cs on cs.match_id = m.id
    group by pg.id, t.id, p.name
    order by pg.created_at desc;
end;
$$;

-- === Extend release_payout to optionally scope to one pooled batch =========
-- When p_pooling_group_id is given, only that group's validated/unpaid
-- sessions are aggregated (a teacher may run both pooled and regular
-- batches), and an explicit commission percent is no longer required —
-- it falls back to the tiered suggestion for that batch's gross.
create or replace function release_payout(
  p_teacher_id text default null,
  p_match_id text default null,
  p_period text default null,
  p_commission_percent numeric default null,
  p_pooling_group_id text default null
)
returns payouts
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_teacher teacher_profiles;
  v_match matches;
  v_group pooling_groups;
  v_gross numeric;
  v_commission_percent numeric;
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

  if p_pooling_group_id is not null then
    select * into v_group from pooling_groups where id::text = p_pooling_group_id or display_id = p_pooling_group_id;
    if v_group.id is null then raise exception 'Pooling group not found'; end if;
    if p_teacher_id is null then
      if v_group.teacher_id is null then raise exception 'This pooling group has no teacher assigned'; end if;
      p_teacher_id := v_group.teacher_id::text;
    end if;
  end if;

  if p_teacher_id is null then
    raise exception 'Provide teacherId, a matchId (FMAPPROVED...), or a poolingGroupId to resolve it automatically';
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
  where m.teacher_id = v_teacher.id
    and s.status = 'ADMIN_VALIDATED'
    and s.payout_id is null
    and (p_pooling_group_id is null or m.pooling_group_id = v_group.id);

  if v_session_ids is null or array_length(v_session_ids, 1) is null then
    raise exception 'No validated, unpaid sessions for this teacher';
  end if;

  v_commission_percent := coalesce(
    p_commission_percent,
    case when p_pooling_group_id is not null then pooling_suggested_commission_percent(v_gross) else null end,
    0
  );
  v_commission := round(v_gross * (v_commission_percent / 100));

  insert into payouts (teacher_id, period, gross_amount, commission_percent, commission_deducted, amount, bank_upi_ref, status, released_at)
  values (v_teacher.id, p_period, v_gross, v_commission_percent, v_commission, v_gross - v_commission, v_teacher.bank_upi_ref, 'RELEASED', now())
  returning * into v_payout;

  update class_sessions set payout_id = v_payout.id where id = any(v_session_ids);

  return v_payout;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
