-- my_requirements() gained new output columns (match_id, match_label,
-- demo_date, parent_accepted_demo, teacher_accepted_demo) for the new
-- parent dashboard. CREATE OR REPLACE can't change return columns, so
-- drop the old version first.
drop function if exists my_requirements();

create or replace function my_requirements()
returns table (
  id uuid, display_id text, subject text, mode text, location text,
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

revoke execute on function my_requirements() from public;
grant execute on function my_requirements() to authenticated;
