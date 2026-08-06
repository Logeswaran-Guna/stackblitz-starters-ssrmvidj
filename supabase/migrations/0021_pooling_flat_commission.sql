-- Replaces the Business Case's tiered 20/30/40% Community Pooling commission
-- (deducted only from the teacher's payout) with a flat 10% charged on
-- BOTH sides, per the founder's direct testing feedback:
--   5 parents x Rs 5,000 each -> each parent owes FM a Rs 500 (10%)
--   surcharge, AND the teacher's payout is still cut by 10% of the
--   Rs 25,000 pooled gross (Rs 2,500) -> FM's total take is 20% of the pool.
--
-- Parent-side collection has no payment gateway (none exists anywhere in
-- this app yet) — it's tracked and collected manually by admin, same
-- pattern as teacher payouts.

-- Per-household amount for a pooled batch (what that family pays), plus
-- whether admin has collected their 10% FM surcharge. Both null/false for
-- every ordinary (non-pooled) match.
alter table matches add column if not exists pool_amount numeric;
alter table matches add column if not exists pool_commission_collected_at timestamptz;

-- Flat 10% now, for both sides — the tiered banding is gone entirely.
create or replace function pooling_suggested_commission_percent(p_gross numeric)
returns numeric
language sql immutable as $$
  select 10;
$$;

-- === Admin: add a household to a pooled batch, now recording their agreed
-- payment amount so their 10% FM surcharge can be computed and tracked. ====
create or replace function add_requirement_to_pooling_group(p_group_id text, p_requirement_id text, p_pool_amount numeric default null)
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
  update matches set pooling_group_id = v_group.id, pool_amount = p_pool_amount where id = v_match.id returning * into v_match;

  return v_match;
end;
$$;

-- === Admin: set/correct a household's pool amount after the fact =========
create or replace function set_pool_amount(p_match_id text, p_pool_amount numeric)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null or v_match.pooling_group_id is null then
    raise exception 'Pooled match not found';
  end if;

  update matches set pool_amount = p_pool_amount where id = v_match.id returning * into v_match;
  return v_match;
end;
$$;

-- === Admin: mark a household's 10% FM surcharge as collected (or undo) ===
create or replace function set_pool_commission_collected(p_match_id text, p_collected boolean)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_match matches;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  v_match := find_match(p_match_id);
  if v_match.id is null or v_match.pooling_group_id is null then
    raise exception 'Pooled match not found';
  end if;

  update matches
  set pool_commission_collected_at = case when p_collected then now() else null end
  where id = v_match.id
  returning * into v_match;

  return v_match;
end;
$$;

-- === Admin: pooling groups overview, now with a per-member breakdown for
-- the parent-side 10% surcharge (name, amount, owed, collected). ==========
-- Postgres won't let CREATE OR REPLACE change a RETURNS TABLE(...) column
-- set — the old 4-column version from 0018 must be dropped first.
drop function if exists admin_pooling_groups();

create or replace function admin_pooling_groups()
returns table (
  id uuid, display_id text, subject text, location text, status text, notes text, created_at timestamptz,
  teacher_id uuid, teacher_display_id text, teacher_name text,
  member_count bigint, unpaid_gross numeric, suggested_commission_percent numeric,
  total_pool_amount numeric, total_parent_commission_owed numeric, total_parent_commission_collected numeric,
  members jsonb
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
      ),
      coalesce(sum(m.pool_amount), 0),
      coalesce(sum(round(m.pool_amount * 0.10)), 0),
      coalesce(sum(round(m.pool_amount * 0.10)) filter (where m.pool_commission_collected_at is not null), 0),
      coalesce(
        (select jsonb_agg(jsonb_build_object(
            'match_id', mm.id,
            'match_display_id', match_display_id(mm),
            'parent_name', pp.name,
            'student_name', s.student_name,
            'pool_amount', mm.pool_amount,
            'commission_owed', round(mm.pool_amount * 0.10),
            'collected', mm.pool_commission_collected_at is not null
          ) order by mm.created_at)
         from matches mm
         join requirements r on r.id = mm.requirement_id
         join profiles pp on pp.id = r.parent_id
         left join students s on s.id = r.student_id
         where mm.pooling_group_id = pg.id),
        '[]'::jsonb
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

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
