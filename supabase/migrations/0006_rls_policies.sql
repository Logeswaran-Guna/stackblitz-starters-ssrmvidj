-- Locks down direct table access. Reads: scoped to "your own data" (or
-- admin). Writes: NONE granted directly to `authenticated` — every INSERT/
-- UPDATE lives inside the SECURITY DEFINER functions in 0003-0005, which
-- run with elevated privilege regardless of these policies. This is what
-- makes those functions the only way to mutate data, mirroring how the
-- Express prototype was the only way to touch dev-db.json.

-- SECURITY DEFINER is load-bearing here, not just a style choice: profiles'
-- own RLS policy (below) calls is_admin() to decide row visibility. If this
-- function ran as the caller (the default), its internal SELECT against
-- profiles would itself be subject to that same policy, which calls
-- is_admin() again — infinite recursion, surfaced by Postgres as "stack
-- depth limit exceeded" (SQLSTATE 54001). Running as definer bypasses RLS
-- on this one lookup and breaks the cycle.
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'ADMIN');
$$;

alter table profiles enable row level security;
alter table students enable row level security;
alter table requirements enable row level security;
alter table teacher_profiles enable row level security;
alter table matches enable row level security;
alter table class_sessions enable row level security;
alter table payouts enable row level security;
alter table id_counters enable row level security;
alter table teacher_languages enable row level security;
alter table teacher_reviews enable row level security;

-- profiles: see yourself, or (if admin) everyone. Teachers/parents see each
-- other's names/phones only through the my_* / admin_* RPCs above, which
-- run as SECURITY DEFINER and bypass this narrower policy on purpose.
create policy profiles_select on profiles for select
  using (id = auth.uid() or is_admin());
-- Column-level grant below restricts this to name/email only, so role can
-- never be touched this way regardless of what the policy itself allows.
create policy profiles_update_self on profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy students_select on students for select
  using (parent_id = auth.uid() or is_admin());

create policy requirements_select on requirements for select
  using (
    parent_id = auth.uid()
    or is_admin()
    or id in (
      select m.requirement_id from matches m
      join teacher_profiles t on t.id = m.teacher_id
      where t.user_id = auth.uid()
    )
  );

create policy teacher_profiles_select on teacher_profiles for select
  using (
    user_id = auth.uid()
    or is_admin()
    or id in (
      select m.teacher_id from matches m
      join requirements r on r.id = m.requirement_id
      where r.parent_id = auth.uid()
    )
  );

create policy matches_select on matches for select
  using (
    is_admin()
    or requirement_id in (select id from requirements where parent_id = auth.uid())
    or teacher_id in (select id from teacher_profiles where user_id = auth.uid())
  );

create policy class_sessions_select on class_sessions for select
  using (
    is_admin()
    or match_id in (
      select m.id from matches m join requirements r on r.id = m.requirement_id
      where r.parent_id = auth.uid()
    )
    or match_id in (
      select m.id from matches m join teacher_profiles t on t.id = m.teacher_id
      where t.user_id = auth.uid()
    )
  );

create policy payouts_select on payouts for select
  using (is_admin() or teacher_id in (select id from teacher_profiles where user_id = auth.uid()));

create policy teacher_languages_select on teacher_languages for select
  using (
    is_admin()
    or teacher_id in (select id from teacher_profiles where user_id = auth.uid())
    or teacher_id in (
      select m.teacher_id from matches m
      join requirements r on r.id = m.requirement_id
      where r.parent_id = auth.uid()
    )
  );

create policy teacher_reviews_select on teacher_reviews for select
  using (
    is_admin()
    or teacher_id in (select id from teacher_profiles where user_id = auth.uid())
    or parent_id = auth.uid()
  );

-- Table grants: SELECT only for direct queries (governed by the policies
-- above); no INSERT/UPDATE/DELETE for the app role at all. EXECUTE on the
-- RPC functions is what actually lets people create/change data.
revoke all on
  profiles, students, requirements, teacher_profiles, matches, class_sessions, payouts, id_counters, teacher_languages, teacher_reviews
from authenticated, anon;

grant select on
  profiles, students, requirements, teacher_profiles, matches, class_sessions, payouts, teacher_languages, teacher_reviews
to authenticated;

grant update (name, email) on profiles to authenticated; -- profile edits only; role stays locked

-- Postgres grants EXECUTE on every new function to PUBLIC by default, which
-- would let a signed-out (anon) caller invoke any of these — revoke that
-- first, then grant only to logged-in users. This also covers every helper
-- function (find_match, match_display_id, next_daily_id, etc.) automatically.
revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;

-- The landing page hero needs real stats before a visitor has signed in —
-- the only function anon gets direct execute on.
grant execute on function public_landing_stats() to anon;
