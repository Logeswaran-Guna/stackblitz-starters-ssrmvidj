-- Restores the original column names that ~25 existing functions across
-- 0003-0022 (my_requirements, log_session, release_payout, approve_teacher,
-- submit_teacher_review, admin_requirements_queue, and many more) have
-- always referenced. At some point the live database's FK columns were
-- renamed (parent_id -> parent_profile_id, user_id/teacher_id ->
-- teacher_profile_id) without those function bodies being updated to
-- match — confirmed live: the entire admin dashboard was returning a raw
-- "column r.parent_id does not exist" error with zero data.
--
-- Rewriting every affected function's body instead of reverting the rename
-- was considered and rejected: several of them (create_match, submit_
-- teacher_review, release_payout, set_teacher_languages) explicitly INSERT
-- using the old names as column lists, which is a much larger and riskier
-- surface to hand-transcribe correctly than reverting 9 column names and
-- updating the 5 small helper functions this project added in
-- 0025_fix_admin_auth_bypass.sql minutes before this bug was found.
--
-- Confirmed via grep: no frontend code queries any of these tables
-- directly (supabase.from(...)) — every read/write goes through RPCs, so
-- reverting the underlying storage column name has no frontend impact.

alter table requirements rename column parent_profile_id to parent_id;
alter table students rename column parent_profile_id to parent_id;
alter table teacher_profiles rename column teacher_profile_id to user_id;
alter table matches rename column teacher_profile_id to teacher_id;
alter table payouts rename column teacher_profile_id to teacher_id;
alter table teacher_languages rename column teacher_profile_id to teacher_id;
alter table teacher_reviews rename column teacher_profile_id to teacher_id;
alter table teacher_reviews rename column parent_profile_id to parent_id;
alter table pooling_groups rename column teacher_profile_id to teacher_id;

-- === Re-point the 5 SECURITY DEFINER helper functions added in 0025 =======
-- These are `language sql` (text-bodied) functions — unlike RLS policies,
-- their bodies are not dependency-tracked by the catalog, so a column
-- rename elsewhere does not automatically update them. Re-created here
-- against the restored names.
create or replace function _teacher_matched_to_requirement(p_requirement_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from matches m
    join teacher_profiles t on t.id = m.teacher_id
    where m.requirement_id = p_requirement_id and t.user_id = auth.uid()
  );
$$;

create or replace function _parent_matched_to_teacher(p_teacher_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from matches m
    join requirements r on r.id = m.requirement_id
    where m.teacher_id = p_teacher_id and r.parent_id = auth.uid()
  );
$$;

create or replace function _match_visible(p_match_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from matches m
    where m.id = p_match_id
    and (
      m.requirement_id in (select id from requirements where parent_id = auth.uid())
      or m.teacher_id in (select id from teacher_profiles where user_id = auth.uid())
    )
  );
$$;

create or replace function _owns_teacher_profile(p_teacher_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from teacher_profiles where id = p_teacher_id and user_id = auth.uid());
$$;

create or replace function _parent_matched_to_pooling_group(p_pooling_group_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from matches m
    join requirements r on r.id = m.requirement_id
    where m.pooling_group_id = p_pooling_group_id and r.parent_id = auth.uid()
  );
$$;

-- === Re-point the 8 policies added in 0025, for certainty ==================
-- RLS policies are catalog-parsed (like views) and would likely have
-- tracked the rename automatically, but recreating explicitly removes any
-- doubt rather than relying on that behavior going unverified.
drop policy if exists requirements_select on requirements;
create policy requirements_select on requirements for select
  using (parent_id = auth.uid() or is_admin() or _teacher_matched_to_requirement(id));

drop policy if exists teacher_profiles_select on teacher_profiles;
create policy teacher_profiles_select on teacher_profiles for select
  using (user_id = auth.uid() or is_admin() or _parent_matched_to_teacher(id));

drop policy if exists matches_select on matches;
create policy matches_select on matches for select
  using (is_admin() or _match_visible(id));

drop policy if exists class_sessions_select on class_sessions;
create policy class_sessions_select on class_sessions for select
  using (is_admin() or _match_visible(match_id));

drop policy if exists payouts_select on payouts;
create policy payouts_select on payouts for select
  using (is_admin() or _owns_teacher_profile(teacher_id));

drop policy if exists teacher_languages_select on teacher_languages;
create policy teacher_languages_select on teacher_languages for select
  using (is_admin() or _owns_teacher_profile(teacher_id) or _parent_matched_to_teacher(teacher_id));

drop policy if exists teacher_reviews_select on teacher_reviews;
create policy teacher_reviews_select on teacher_reviews for select
  using (is_admin() or _owns_teacher_profile(teacher_id) or parent_id = auth.uid());

drop policy if exists pooling_groups_select on pooling_groups;
create policy pooling_groups_select on pooling_groups for select
  using (is_admin() or _owns_teacher_profile(teacher_id) or _parent_matched_to_pooling_group(id));

revoke execute on all functions in schema public from anon;
revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
grant execute on function academy_courses_public() to anon;
grant execute on function submit_academy_enrollment(text, text, text, text, text, text, text) to anon;
grant execute on function public_landing_stats() to anon;
