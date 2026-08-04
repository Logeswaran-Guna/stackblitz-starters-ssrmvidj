-- ============================================================
-- Future Minds — Phase 12 schema sync
--
-- Adds a public (signed-out-callable) RPC returning real hero stats for
-- the landing page — no hardcoded/fabricated numbers. "Onboarded" tutors
-- means KYC-approved specifically, not just registered.
--
-- Run this against future-minds-test AFTER 0013_parent_status_cascade_both_ways.sql.
-- ============================================================

create or replace function public_landing_stats()
returns table (tutors_onboarded int, classes_completed int)
language sql security definer set search_path = public as $$
  select
    (select count(*) from teacher_profiles where kyc_status = 'APPROVED')::int,
    (select count(*) from class_sessions where status in ('PARENT_CONFIRMED', 'ADMIN_VALIDATED'))::int;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;

-- The landing page hero needs real stats before a visitor has signed in —
-- the only function anon gets direct execute on.
grant execute on function public_landing_stats() to anon;
