-- CRITICAL SECURITY FIX. Two independent, confirmed-live bugs, both fixed
-- here:
--
-- (1) Every admin-gated RPC (26 functions, e.g. admin_academy_courses,
--     release_payout, set_teacher_kyc_status) guards with:
--       if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
--     current_profile() returns NULL for an unauthenticated caller (no
--     profiles row matches auth.uid() = NULL). NULL <> 'ADMIN' evaluates to
--     NULL in SQL, and `if NULL` is treated as false in PL/pgSQL — so the
--     exception silently never fires and the function runs as if the check
--     passed. Confirmed live: admin_academy_courses, admin_requirements_queue,
--     admin_teachers_directory, admin_sessions_queue and admin_pooling_groups
--     all executed successfully for a fully anonymous caller (no session at
--     all, just the public anon key).
--
--     Separately (and this is *why* the anon call even reached the function
--     body instead of being rejected at the grant-check stage): despite every
--     migration's "revoke execute ... from public; grant execute ... to
--     authenticated;", the `anon` role still had live EXECUTE on every
--     function. REVOKE ... FROM PUBLIC does not retract a role's own
--     independent grant, and default privileges re-grant PUBLIC execute on
--     every newly created function regardless of prior revokes on other
--     functions. Fixed below by revoking from `anon` explicitly and locking
--     future functions via ALTER DEFAULT PRIVILEGES.
--
--     Fixing current_profile() to raise instead of returning NULL is
--     defense-in-depth on top of the grant fix: even if a role/grant
--     regresses again later, every one of the 26+ functions built on
--     `me := current_profile()` fails closed instead of failing open.
--
-- (2) requirements_select, teacher_profiles_select and matches_select each
--     inline-subquery into one another (requirements -> matches ->
--     teacher_profiles -> matches -> requirements...), and
--     payouts_select/class_sessions_select/teacher_reviews_select/
--     teacher_languages_select/pooling_groups_select all subquery into that
--     same cycle. Postgres detects the circular RLS policy dependency and
--     raises "infinite recursion detected in policy for relation X" (42P17)
--     for ANY caller hitting these tables directly (not through the RPCs).
--     Not a data leak — every attempt errors out, zero rows returned — but a
--     real reliability bug. Fixed the same way is_admin() already avoids
--     this: SECURITY DEFINER helper functions bypass RLS on the one lookup
--     they perform, so evaluating one table's policy no longer requires
--     evaluating another's.
--
-- Note on column names: this migration's first draft used the column names
-- from 0001/0006/0018's *source text* (parent_id, user_id, teacher_id) and
-- failed against the live database with "column does not exist". The live
-- schema (confirmed via information_schema.columns) actually has
-- requirements.parent_profile_id, teacher_profiles.teacher_profile_id (FK to
-- profiles.id — i.e. what the file calls user_id), and teacher_profile_id
-- (FK to teacher_profiles.id) on matches/payouts/teacher_languages/
-- teacher_reviews/pooling_groups. The live database was renamed at some
-- point without the migration files being updated to match — this migration
-- is written against the real, live column names, confirmed directly via
-- information_schema before writing this version.

-- === (1b) current_profile(): fail closed instead of returning NULL ========
create or replace function current_profile()
returns profiles
language plpgsql
stable
set search_path = public
as $$
declare
  v_profile profiles;
begin
  select * into v_profile from profiles where id = auth.uid();
  if v_profile.id is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  return v_profile;
end;
$$;

-- === (2) SECURITY DEFINER helpers to break the RLS policy cycle ===========
create or replace function _teacher_matched_to_requirement(p_requirement_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from matches m
    join teacher_profiles t on t.id = m.teacher_profile_id
    where m.requirement_id = p_requirement_id and t.teacher_profile_id = auth.uid()
  );
$$;

create or replace function _parent_matched_to_teacher(p_teacher_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from matches m
    join requirements r on r.id = m.requirement_id
    where m.teacher_profile_id = p_teacher_id and r.parent_profile_id = auth.uid()
  );
$$;

create or replace function _match_visible(p_match_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from matches m
    where m.id = p_match_id
    and (
      m.requirement_id in (select id from requirements where parent_profile_id = auth.uid())
      or m.teacher_profile_id in (select id from teacher_profiles where teacher_profile_id = auth.uid())
    )
  );
$$;

create or replace function _owns_teacher_profile(p_teacher_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from teacher_profiles where id = p_teacher_id and teacher_profile_id = auth.uid());
$$;

create or replace function _parent_matched_to_pooling_group(p_pooling_group_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from matches m
    join requirements r on r.id = m.requirement_id
    where m.pooling_group_id = p_pooling_group_id and r.parent_profile_id = auth.uid()
  );
$$;

-- === (2b) Rewrite the affected SELECT policies to use the helpers =========
drop policy if exists requirements_select on requirements;
create policy requirements_select on requirements for select
  using (parent_profile_id = auth.uid() or is_admin() or _teacher_matched_to_requirement(id));

drop policy if exists teacher_profiles_select on teacher_profiles;
create policy teacher_profiles_select on teacher_profiles for select
  using (teacher_profile_id = auth.uid() or is_admin() or _parent_matched_to_teacher(id));

drop policy if exists matches_select on matches;
create policy matches_select on matches for select
  using (is_admin() or _match_visible(id));

drop policy if exists class_sessions_select on class_sessions;
create policy class_sessions_select on class_sessions for select
  using (is_admin() or _match_visible(match_id));

drop policy if exists payouts_select on payouts;
create policy payouts_select on payouts for select
  using (is_admin() or _owns_teacher_profile(teacher_profile_id));

drop policy if exists teacher_languages_select on teacher_languages;
create policy teacher_languages_select on teacher_languages for select
  using (is_admin() or _owns_teacher_profile(teacher_profile_id) or _parent_matched_to_teacher(teacher_profile_id));

drop policy if exists teacher_reviews_select on teacher_reviews;
create policy teacher_reviews_select on teacher_reviews for select
  using (is_admin() or _owns_teacher_profile(teacher_profile_id) or parent_profile_id = auth.uid());

drop policy if exists pooling_groups_select on pooling_groups;
create policy pooling_groups_select on pooling_groups for select
  using (is_admin() or _owns_teacher_profile(teacher_profile_id) or _parent_matched_to_pooling_group(id));

-- === (1a) Explicit anon revoke + default-privilege hardening ===============
-- Runs last so it covers every function defined above too (current_profile
-- and the 5 new _* helpers), not just the ones that existed before this file.
revoke execute on all functions in schema public from anon;
revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;

-- Without this, Postgres grants EXECUTE to PUBLIC (which anon inherits) on
-- every function created from here on, regardless of the blanket revoke
-- above — this is what silently undid every prior migration's revoke.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public grant execute on functions to authenticated;

-- Re-grant only the 3 functions genuinely meant for signed-out visitors.
grant execute on function academy_courses_public() to anon;
grant execute on function submit_academy_enrollment(text, text, text, text, text, text, text) to anon;
grant execute on function public_landing_stats() to anon;
