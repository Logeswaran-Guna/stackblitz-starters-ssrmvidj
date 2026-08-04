-- Prepares accounts for the browser click-through test.
--   1. Confirms the parent's email (e2e.parent.browser.test1@gmail.com) —
--      it was created for real via the /find-tutor signup in the browser,
--      just needs its confirmation bypassed so we can log in immediately.
--   2. Creates a TEACHER account directly (bypassing the email-confirmation
--      step entirely, avoiding the "email rate limit exceeded" we just hit)
--      and fills out their teacher profile.
--   3. Creates an ADMIN account the same way and promotes it.
-- All three use password: TestPass123!
do $$
declare
  v_teacher_id uuid;
  v_admin_id uuid;
begin
  -- 1. Confirm the real browser-created parent account.
  update auth.users
  set email_confirmed_at = now()
  where email = 'e2e.parent.browser.test1@gmail.com'
    and email_confirmed_at is null;

  -- 2. Seed the teacher account (pre-confirmed).
  insert into auth.users (instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'e2e.teacher.sql@futureminds.example',
    '9' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
    crypt('TestPass123!', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}',
    '{"name":"Test Teacher SQL","role":"TEACHER","consent":true}', now(), now(), '', '', '', '')
  returning id into v_teacher_id;

  perform set_config('request.jwt.claims', json_build_object('sub', v_teacher_id)::text, true);
  perform upsert_teacher_profile(
    p_qualification := 'M.Sc Mathematics', p_subjects := array['Mathematics', 'Science'],
    p_preferred_locations := array['Anna Nagar', 'Coimbatore'], p_teaching_mode := 'Online Classes',
    p_time_slot := 'Weekday evenings', p_bank_upi_ref := 'teacher@upi'
  );

  -- 3. Seed the admin account (pre-confirmed) and promote it.
  insert into auth.users (instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'e2e.admin.sql@futureminds.example',
    '9' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
    crypt('TestPass123!', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}',
    '{"name":"Test Admin SQL","role":"PARENT","consent":true}', now(), now(), '', '', '', '')
  returning id into v_admin_id;

  update profiles set role = 'ADMIN' where id = v_admin_id;

  raise notice '=== READY === teacher login: e2e.teacher.sql@futureminds.example / admin login: e2e.admin.sql@futureminds.example / password for both: TestPass123!';
end $$;
