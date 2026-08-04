-- ============================================================
-- Future Minds — Phase 11 follow-up
--
-- admin_set_profile_status previously only cascaded a PARENT's status to
-- their students when removing/deleting. Restoring a parent back to
-- Active/Idle left the kids stuck on Removed. Now any status change on a
-- parent cascades to their students, in either direction — matching "we
-- done action on parent that automatically applies to tied kids."
--
-- Run this against future-minds-test AFTER 0012_phase11_auto_status.sql.
-- ============================================================

create or replace function admin_set_profile_status(p_profile_id uuid, p_status entity_status)
returns profiles
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_target profiles;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  update profiles set status = p_status where id = p_profile_id returning * into v_target;
  if v_target.id is null then raise exception 'Profile not found'; end if;

  if v_target.role = 'PARENT' then
    update students set status = p_status where parent_id = v_target.id;
  end if;

  return v_target;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
