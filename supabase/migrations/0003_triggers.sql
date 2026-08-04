-- Auth wiring: turns a Supabase auth.users signup into a `profiles` row,
-- mirroring auth.js's /verify-otp "new user" branch. The frontend passes
-- name / role / consent via the signup call's user metadata, e.g.
--   supabase.auth.signInWithOtp({ phone, options: { data: {
--     name, role, consent: true
--   }}})
-- Raising inside this AFTER INSERT trigger rolls back the whole signup
-- transaction (including the auth.users row), so "no consent -> no account"
-- still holds, same as the old hard 400 on missing consent.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role user_role;
  v_display_id text;
begin
  if coalesce((new.raw_user_meta_data->>'consent')::boolean, false) is not true then
    raise exception 'Terms & Privacy consent is required';
  end if;
  if coalesce(new.raw_user_meta_data->>'name', '') = '' then
    raise exception 'New account requires a name';
  end if;

  -- Never ADMIN via public signup — same guarantee as the Express prototype.
  v_role := case when (new.raw_user_meta_data->>'role') = 'TEACHER' then 'TEACHER' else 'PARENT' end;

  v_display_id := case when v_role = 'TEACHER'
    then next_daily_id('teacher_daily', 'FMTEACH')
    else next_daily_id('parent_daily', 'FMPAR')
  end;

  insert into profiles (id, display_id, role, name, phone, email, consent_at)
  values (
    new.id, v_display_id, v_role,
    new.raw_user_meta_data->>'name',
    coalesce(new.phone, new.raw_user_meta_data->>'phone'),
    new.email,
    now()
  );

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- "A parent can register up to 4 students" — src/routes/requirements.js's
-- `existingCount >= 4` check, enforced here so it holds no matter what
-- calls INSERT (not just the submit_requirement RPC).
create or replace function enforce_max_students()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from students where parent_id = new.parent_id) >= 4 then
    raise exception 'You can register up to 4 students per parent account. To add a subject for an existing student instead, pass their Student ID.';
  end if;
  return new;
end;
$$;

create trigger trg_max_students
  before insert on students
  for each row execute function enforce_max_students();
