-- Referral program: every parent/teacher can share their own existing
-- display_id as a referral code (no new code-generation needed). Points
-- are credited to the REFERRER only once the referred person's own
-- first match reaches CONFIRMED — not on mere signup, to avoid rewarding
-- junk signups. Points redeem into a discount code at an admin-editable
-- rate; the code is applied by admin at the same moment they already
-- handle money in this app (marking the parent's one-time fee collected,
-- or releasing a teacher's payout), capped at 50% of that fee or 2
-- months of the teacher's stated monthly rate at the flat 10% commission
-- respectively. Excess above the cap is forfeited — the code is fully
-- consumed either way (no partial carry-forward in this version).

-- === Schema ==================================================================

alter table profiles add column if not exists referred_by_profile_id uuid references profiles(id);

create table if not exists referral_ledger (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  referrer_profile_id uuid not null references profiles(id) on delete cascade,
  referred_profile_id uuid not null references profiles(id) on delete cascade,
  referred_role user_role not null,
  points int not null default 100,
  source_match_id uuid references matches(id) on delete set null,
  created_at timestamptz not null default now(),
  -- The actual "credited once" guarantee — independent of any app-level
  -- guard logic in _credit_referral() below.
  unique (referred_profile_id)
);

create table if not exists discount_codes (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  profile_id uuid not null references profiles(id) on delete cascade,
  points_redeemed int not null,
  -- Locked in at redemption time so a later admin rate change doesn't
  -- retroactively alter the value of codes already issued.
  rate_snapshot numeric not null,
  code_value numeric not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'APPLIED', 'EXPIRED')),
  applied_to_match_id uuid references matches(id) on delete set null,
  applied_to_payout_id uuid references payouts(id) on delete set null,
  applied_amount numeric,
  applied_at timestamptz,
  created_at timestamptz not null default now()
);

-- Generic admin-editable key/value settings — first of its kind here, so
-- future admin-tunable knobs (not just the referral rate) can reuse this
-- instead of spawning another one-off table.
create table if not exists platform_settings (
  key text primary key,
  value text not null,
  updated_by uuid references profiles(id),
  updated_at timestamptz not null default now()
);

insert into platform_settings (key, value)
values ('referral_rate_rupees_per_point', '0.50')
on conflict (key) do nothing;

alter table matches add column if not exists referral_discount_amount numeric;
alter table matches add column if not exists referral_discount_code text;
alter table payouts add column if not exists referral_discount_amount numeric;
alter table payouts add column if not exists referral_discount_code text;

alter table referral_ledger enable row level security;
alter table discount_codes enable row level security;
alter table platform_settings enable row level security;
revoke all on referral_ledger from authenticated, anon;
revoke all on discount_codes from authenticated, anon;
revoke all on platform_settings from authenticated, anon;

-- === handle_new_user: capture the referral code at signup ==================
-- Same trigger signature (no params), so a plain create-or-replace is
-- safe — no drop needed. Unknown/blank code is silently ignored, never
-- blocks signup.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role user_role;
  v_display_id text;
  v_referrer profiles;
begin
  if coalesce((new.raw_user_meta_data->>'consent')::boolean, false) is not true then
    raise exception 'Terms & Privacy consent is required';
  end if;
  if coalesce(new.raw_user_meta_data->>'name', '') = '' then
    raise exception 'New account requires a name';
  end if;

  v_role := case when (new.raw_user_meta_data->>'role') = 'TEACHER' then 'TEACHER' else 'PARENT' end;

  v_display_id := case when v_role = 'TEACHER'
    then next_daily_id('teacher_daily', 'FMTEACH')
    else next_daily_id('parent_daily', 'FMPAR')
  end;

  if coalesce(new.raw_user_meta_data->>'referral_code', '') <> '' then
    select * into v_referrer from profiles where display_id = new.raw_user_meta_data->>'referral_code';
  end if;

  insert into profiles (id, display_id, role, name, phone, email, consent_at, referred_by_profile_id)
  values (
    new.id, v_display_id, v_role,
    new.raw_user_meta_data->>'name',
    coalesce(new.phone, new.raw_user_meta_data->>'phone'),
    new.email,
    now(),
    v_referrer.id
  );

  return new;
end;
$$;

-- === Internal: credit a referrer once their referred person converts =======
create or replace function _credit_referral(p_referred_profile_id uuid, p_source_match_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_referred profiles;
  v_referrer profiles;
  v_inserted referral_ledger;
begin
  select * into v_referred from profiles where id = p_referred_profile_id;
  if v_referred.id is null or v_referred.referred_by_profile_id is null then
    return;
  end if;

  select * into v_referrer from profiles where id = v_referred.referred_by_profile_id;
  if v_referrer.id is null then
    return;
  end if;

  insert into referral_ledger (display_id, referrer_profile_id, referred_profile_id, referred_role, points, source_match_id)
  values (next_daily_id('referral_daily', 'FMREF'), v_referrer.id, v_referred.id, v_referred.role, 100, p_source_match_id)
  on conflict (referred_profile_id) do nothing
  returning * into v_inserted;

  if v_inserted.id is not null then
    perform _notify(v_referrer.role::text, v_referrer.id, 'REFERRAL_CREDITED', 'You earned referral points!',
      'Your referral just confirmed their first match — you earned ' || v_inserted.points || ' points. Check your dashboard to redeem them.');
  end if;
end;
$$;

-- === approve_teacher: credit both sides' referrers on confirmation =========
-- Same single-param signature as 0028's version — plain create-or-replace,
-- no drop needed.
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

  perform _credit_referral(v_req.parent_id, v_match.id);
  perform _credit_referral(v_teacher.user_id, v_match.id);

  return v_match;
end;
$$;

-- === Own referral summary / redemption ======================================

create or replace function my_referral_summary()
returns table (
  referral_code text,
  points_balance int,
  points_lifetime_earned int,
  points_redeemed int,
  referred_count int
)
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_earned int;
  v_redeemed int;
  v_count int;
begin
  if me.role not in ('PARENT', 'TEACHER') then raise exception 'Not authorized'; end if;

  select coalesce(sum(points), 0)::int, coalesce(count(*), 0)::int
    into v_earned, v_count
    from referral_ledger where referrer_profile_id = me.id;

  select coalesce(sum(dc.points_redeemed), 0)::int into v_redeemed
    from discount_codes dc where dc.profile_id = me.id;

  return query select me.display_id, v_earned - v_redeemed, v_earned, v_redeemed, v_count;
end;
$$;

create or replace function redeem_referral_points(p_points int)
returns discount_codes
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_earned int;
  v_redeemed int;
  v_balance int;
  v_rate numeric;
  v_code discount_codes;
begin
  if me.role not in ('PARENT', 'TEACHER') then raise exception 'Not authorized'; end if;
  if p_points is null or p_points <= 0 then raise exception 'Points must be positive'; end if;

  select coalesce(sum(points), 0)::int into v_earned from referral_ledger where referrer_profile_id = me.id;
  select coalesce(sum(points_redeemed), 0)::int into v_redeemed from discount_codes where profile_id = me.id;
  v_balance := v_earned - v_redeemed;

  if p_points > v_balance then
    raise exception 'Not enough points — you have %, requested %', v_balance, p_points;
  end if;

  select value::numeric into v_rate from platform_settings where key = 'referral_rate_rupees_per_point';
  v_rate := coalesce(v_rate, 0.5);

  insert into discount_codes (display_id, profile_id, points_redeemed, rate_snapshot, code_value, status)
  values (next_daily_id('discount_daily', 'FMDISC'), me.id, p_points, v_rate, round(p_points * v_rate, 2), 'ACTIVE')
  returning * into v_code;

  return v_code;
end;
$$;

create or replace function my_discount_codes()
returns setof discount_codes
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role not in ('PARENT', 'TEACHER') then raise exception 'Not authorized'; end if;
  return query select * from discount_codes where profile_id = me.id order by created_at desc;
end;
$$;

-- === Admin: ledger view, settings, and applying codes to real money ========

create or replace function admin_referral_ledger()
returns table (
  id uuid, display_id text,
  referrer_display_id text, referrer_name text,
  referred_display_id text, referred_name text, referred_role user_role,
  points int, created_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  return query
    select rl.id, rl.display_id,
      pr.display_id, pr.name,
      pd.display_id, pd.name, rl.referred_role,
      rl.points, rl.created_at
    from referral_ledger rl
    join profiles pr on pr.id = rl.referrer_profile_id
    join profiles pd on pd.id = rl.referred_profile_id
    order by rl.created_at desc;
end;
$$;

create or replace function admin_referral_settings()
returns setof platform_settings
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  return query select * from platform_settings order by key;
end;
$$;

create or replace function admin_update_setting(p_key text, p_value text)
returns platform_settings
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_setting platform_settings;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  insert into platform_settings (key, value, updated_by, updated_at)
  values (p_key, p_value, me.id, now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at
  returning * into v_setting;

  return v_setting;
end;
$$;

create or replace function admin_apply_discount_to_fee(p_match_id text, p_code text)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
  v_req requirements;
  v_code discount_codes;
  v_applied numeric;
  v_cap numeric;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null then raise exception 'Match not found'; end if;
  if v_match.parent_onetime_fee_amount is null then raise exception 'No one-time fee on this match to discount'; end if;

  select r.* into v_req from requirements r where r.id = v_match.requirement_id;

  select * into v_code from discount_codes where display_id = p_code or id::text = p_code;
  if v_code.id is null then raise exception 'Discount code not found'; end if;
  if v_code.status <> 'ACTIVE' then raise exception 'Discount code already used or expired'; end if;
  if v_code.profile_id <> v_req.parent_id then raise exception 'This code does not belong to this requirement''s parent'; end if;

  v_cap := 0.5 * v_match.parent_onetime_fee_amount;
  v_applied := least(v_code.code_value, v_cap);

  update matches
  set referral_discount_amount = v_applied, referral_discount_code = v_code.display_id
  where id = v_match.id
  returning * into v_match;

  update discount_codes
  set status = 'APPLIED', applied_to_match_id = v_match.id, applied_amount = v_applied, applied_at = now()
  where id = v_code.id;

  return v_match;
end;
$$;

create or replace function admin_apply_discount_to_payout(p_payout_id text, p_code text)
returns payouts
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_payout payouts;
  v_teacher teacher_profiles;
  v_code discount_codes;
  v_applied numeric;
  v_cap numeric;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  select * into v_payout from payouts where id::text = p_payout_id;
  if v_payout.id is null then raise exception 'Payout not found'; end if;

  select * into v_teacher from teacher_profiles where id = v_payout.teacher_id;

  select * into v_code from discount_codes where display_id = p_code or id::text = p_code;
  if v_code.id is null then raise exception 'Discount code not found'; end if;
  if v_code.status <> 'ACTIVE' then raise exception 'Discount code already used or expired'; end if;
  if v_code.profile_id <> v_teacher.user_id then raise exception 'This code does not belong to this teacher'; end if;

  -- 2 months of the teacher's own stated monthly rate at the platform's
  -- flat 10% commission — the closest existing field to "what both
  -- parties committed" (flagged for founder confirmation in the plan).
  v_cap := 2 * coalesce(v_teacher.rate_expectation, 0) * 0.10;
  v_applied := least(v_code.code_value, v_cap);

  update payouts
  set commission_deducted = greatest(0, commission_deducted - v_applied),
      amount = amount + v_applied,
      referral_discount_amount = v_applied,
      referral_discount_code = v_code.display_id
  where id = v_payout.id
  returning * into v_payout;

  update discount_codes
  set status = 'APPLIED', applied_to_payout_id = v_payout.id, applied_amount = v_applied, applied_at = now()
  where id = v_code.id;

  return v_payout;
end;
$$;

-- === admin_requirements_queue: surface the applied discount to admin =======
-- RETURNS TABLE column list is changing, so the old signature must be
-- dropped first (same reasoning as every prior RETURNS TABLE change in
-- this project).
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
  parent_onetime_fee_amount numeric, parent_fee_collected boolean,
  referral_discount_amount numeric, referral_discount_code text
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

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
grant execute on function general_notifications() to anon;
