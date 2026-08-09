-- Ops visibility: (1) an admin funnel view of where requirements drop off
-- between submission and a confirmed match, and (2) a per-teacher payout
-- statement RPC for CSV export. Both are pure read-only additions with
-- no schema changes and no interdependency.

-- === Admin funnel stats ======================================================
-- Each requirement is classified into exactly one stage, checked in
-- priority order (a requirement with both a declined and a later
-- confirmed match counts as CONFIRMED, not DECLINED).
create or replace function admin_funnel_stats()
returns table (
  total_requirements int,
  no_match int,
  matched int,
  demo_stage int,
  confirmed int,
  declined int
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
  select
    count(*)::int,
    count(*) filter (where stage.name = 'NO_MATCH')::int,
    count(*) filter (where stage.name = 'MATCHED')::int,
    count(*) filter (where stage.name = 'DEMO')::int,
    count(*) filter (where stage.name = 'CONFIRMED')::int,
    count(*) filter (where stage.name = 'DECLINED')::int
  from requirements r
  cross join lateral (
    select case
      when exists (select 1 from matches m where m.requirement_id = r.id and m.status = 'CONFIRMED')
        then 'CONFIRMED'
      when exists (select 1 from matches m where m.requirement_id = r.id and m.status in ('DEMO_PROPOSED', 'DEMO_SCHEDULED'))
        then 'DEMO'
      when exists (select 1 from matches m where m.requirement_id = r.id and m.status = 'PROPOSED')
        then 'MATCHED'
      when exists (select 1 from matches m where m.requirement_id = r.id)
        then 'DECLINED'
      else 'NO_MATCH'
    end as name
  ) stage;
end;
$$;

-- === Admin: per-teacher payout statement ====================================
-- setof payouts (not an explicit column list) so this automatically
-- inherits any future payouts columns — including 0031's
-- referral_discount_amount/code — with no drop ever needed here.
create or replace function admin_teacher_payouts(p_teacher_id text)
returns setof payouts
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_teacher teacher_profiles;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  v_teacher := find_teacher(p_teacher_id);
  if v_teacher.id is null then raise exception 'Teacher not found'; end if;

  return query select * from payouts where teacher_id = v_teacher.id order by released_at desc;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
grant execute on function general_notifications() to anon;
revoke execute on function _cron_nudge_stalled_matches() from authenticated;
