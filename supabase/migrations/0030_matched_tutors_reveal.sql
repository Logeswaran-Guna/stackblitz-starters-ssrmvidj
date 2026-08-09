-- Parent-facing "matched tutors" reveal: for a requirement that has no
-- confirmed match yet, show the parent a redacted card (photo, name,
-- subjects, fee, rating, area — never the match score, never a full
-- address) for every APPROVED/ACTIVE teacher whose fit is >=60%. This is
-- purely informational — admin's existing Find-Matching-Tutors ->
-- create_match -> propose_demo flow is completely unchanged; this runs
-- in parallel as a trust-building view, not a new matching path.
--
-- The scoring algorithm is a straight SQL port of computeMatchScore() /
-- overlapRatio() / fuzzyOverlap() in app/admin/types.ts (same weights:
-- subject 35, mode 20, location 15, availability 10, rating 10, rateFit
-- 10) so the admin's "X% match" badge and this reveal agree on what
-- counts as a good fit. Computation happens entirely server-side inside
-- a SECURITY DEFINER function — the parent's browser never receives the
-- raw teacher_profiles rows, the full candidate list, or any score.

create or replace function _fuzzy_overlap(a text[], b text[])
returns boolean
language sql
immutable
as $$
  select exists (
    select 1
    from unnest(a) as ia
    join unnest(b) as ib
      on length(trim(lower(ia))) > 0
     and length(trim(lower(ib))) > 0
     and (trim(lower(ia)) like '%' || trim(lower(ib)) || '%'
       or trim(lower(ib)) like '%' || trim(lower(ia)) || '%')
  );
$$;

create or replace function _overlap_ratio(p_want text[], p_have text[])
returns numeric
language plpgsql
immutable
as $$
declare
  v_want text[] := array(select trim(lower(x)) from unnest(coalesce(p_want, '{}')) x where trim(x) <> '');
  v_have text[] := array(select trim(lower(x)) from unnest(coalesce(p_have, '{}')) x where trim(x) <> '');
  v_matched int;
begin
  if array_length(v_want, 1) is null then
    return 0.7;
  end if;
  if array_length(v_have, 1) is null then
    return 0.3;
  end if;

  select count(*) into v_matched
  from unnest(v_want) w
  where exists (
    select 1 from unnest(v_have) h
    where h like '%' || w || '%' or w like '%' || h || '%'
  );

  return v_matched::numeric / array_length(v_want, 1);
end;
$$;

create or replace function _teacher_match_score(
  p_subject text,
  p_mode text[],
  p_location text,
  p_schedule_pref text,
  p_budget numeric,
  p_teacher teacher_profiles,
  p_rating_avg numeric
)
returns int
language plpgsql
immutable
as $$
declare
  v_subject_score numeric;
  v_mode_score numeric;
  v_location_relevant boolean;
  v_location_score numeric;
  v_availability_score numeric;
  v_rating_score numeric;
  v_ratefit_score numeric := 0.7;
  v_weighted numeric;
begin
  v_subject_score := case when _fuzzy_overlap(array[p_subject], coalesce(p_teacher.subjects, '{}')) then 1 else 0 end;
  v_mode_score := _overlap_ratio(p_mode, p_teacher.teaching_mode);

  v_location_relevant := exists (select 1 from unnest(coalesce(p_mode, '{}')) m where m <> 'Online');
  v_location_score := case
    when not v_location_relevant then 1
    when p_location is not null then _overlap_ratio(array[p_location], p_teacher.preferred_locations)
    else 0.7
  end;

  v_availability_score := _overlap_ratio(
    case when p_schedule_pref is not null then array[p_schedule_pref] else array[]::text[] end,
    p_teacher.availability
  );

  v_rating_score := case when p_rating_avg is not null then least(p_rating_avg, 5) / 5 else 0.6 end;

  if p_budget is not null and p_budget > 0 and p_teacher.rate_expectation is not null then
    if p_teacher.rate_expectation <= p_budget then
      v_ratefit_score := 1;
    else
      v_ratefit_score := greatest(0, 1 - (p_teacher.rate_expectation - p_budget) / p_budget);
    end if;
  end if;

  v_weighted := v_subject_score * 35 + v_mode_score * 20 + v_location_score * 15
    + v_availability_score * 10 + v_rating_score * 10 + v_ratefit_score * 10;

  return round(v_weighted);
end;
$$;

create or replace function parent_matched_tutors(p_requirement_id text)
returns table (
  teacher_id uuid,
  display_id text,
  name text,
  photo_url text,
  subjects text[],
  rate_expectation numeric,
  rating_avg numeric,
  rating_count int,
  area_city text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  me profiles := current_profile();
  v_req requirements;
begin
  if me.role <> 'PARENT' then
    raise exception 'Parent only';
  end if;

  v_req := find_requirement(p_requirement_id);
  if v_req.id is null or v_req.parent_id <> me.id then
    raise exception 'Not your requirement';
  end if;

  return query
    select
      t.id,
      t.display_id,
      p.name,
      t.photo_url,
      t.subjects,
      t.rate_expectation,
      round(ratings.avg_rating, 1),
      coalesce(ratings.review_count, 0)::int,
      t.area_city
    from teacher_profiles t
    join profiles p on p.id = t.user_id
    left join lateral (
      select avg(tr.rating) as avg_rating, count(*) as review_count
      from teacher_reviews tr
      where tr.teacher_id = t.id
    ) ratings on true
    where t.kyc_status = 'APPROVED'
      and p.status = 'ACTIVE'
      and _teacher_match_score(v_req.subject, v_req.mode, v_req.location, v_req.schedule_pref, v_req.budget, t, ratings.avg_rating) >= 60
    order by _teacher_match_score(v_req.subject, v_req.mode, v_req.location, v_req.schedule_pref, v_req.budget, t, ratings.avg_rating) desc;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
grant execute on function general_notifications() to anon;
