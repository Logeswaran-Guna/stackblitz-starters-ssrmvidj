-- Nudge whichever side hasn't accepted a proposed demo after 3+ days of
-- silence, via the existing in-app notification system. Fires at most
-- once per match (nudged_at gate) — no repeat spam.
--
-- This function is deliberately NOT gated by current_profile()/a role
-- check the way every other RPC in this project is — a service-role
-- caller (the only caller this should ever have) has no auth.uid(), so
-- current_profile() would fail closed against it anyway. Instead it's
-- locked down purely by grant: revoked from `authenticated` at the
-- bottom of this file, so the browser SDK can never reach it — only a
-- direct service-role Postgres connection (used by the cron route) can.

alter table matches add column if not exists nudged_at timestamptz;

create or replace function _cron_nudge_stalled_matches()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match record;
  v_count int := 0;
begin
  for v_match in
    select m.*, r.parent_id, r.subject, t.user_id as teacher_user_id
    from matches m
    join requirements r on r.id = m.requirement_id
    join teacher_profiles t on t.id = m.teacher_id
    where m.status in ('DEMO_PROPOSED', 'DEMO_SCHEDULED')
      and m.dead = false
      and m.demo_proposed_at is not null
      and m.demo_proposed_at <= now() - interval '3 days'
      and not (m.parent_accepted_demo and m.teacher_accepted_demo)
      and m.nudged_at is null
  loop
    if not v_match.parent_accepted_demo then
      perform _notify('PARENT', v_match.parent_id, 'DEMO_STALLED',
        'Your demo is still waiting on you',
        'You have a demo proposed for ' || v_match.subject || ' that''s still awaiting your response. Please accept it, or let us know if you need a different time.');
    end if;
    if not v_match.teacher_accepted_demo then
      perform _notify('TEACHER', v_match.teacher_user_id, 'DEMO_STALLED',
        'A proposed demo is waiting on you',
        'You have a demo proposed for ' || v_match.subject || ' that''s still awaiting your response. Please accept it, or let us know if you need a different time.');
    end if;

    update matches set nudged_at = now() where id = v_match.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
grant execute on function general_notifications() to anon;
revoke execute on function _cron_nudge_stalled_matches() from authenticated;
