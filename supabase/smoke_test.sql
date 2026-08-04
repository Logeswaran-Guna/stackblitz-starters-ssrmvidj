-- End-to-end smoke test: creates 3 test accounts and walks them through the
-- whole lifecycle (requirement -> match -> demo -> approval -> attendance ->
-- payout), printing NOTICEs so you can see each step succeed in the SQL
-- Editor's output/log pane. Safe to run multiple times (each run makes new
-- test users/rows); safe to delete afterward.
do $$
declare
  v_parent_id uuid;
  v_teacher_id uuid;
  v_admin_id uuid;
  v_teacher_profile teacher_profiles;
  v_req requirements;
  v_match matches;
  v_session class_sessions;
  v_payout payouts;
begin
  -- 1. Seed three auth users directly (fires the same handle_new_user
  -- trigger a real signup would). Using timestamp-suffixed emails so this
  -- script can be re-run without a duplicate-email error.
  insert into auth.users (instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'test.parent.' || extract(epoch from now())::text || '@futureminds.test',
    '9' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
    crypt('Testpass123!', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}',
    '{"name":"Test Parent","role":"PARENT","consent":true}', now(), now(), '', '', '', '')
  returning id into v_parent_id;

  insert into auth.users (instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'test.teacher.' || extract(epoch from now())::text || '@futureminds.test',
    '9' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
    crypt('Testpass123!', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}',
    '{"name":"Test Teacher","role":"TEACHER","consent":true}', now(), now(), '', '', '', '')
  returning id into v_teacher_id;

  insert into auth.users (instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'test.admin.' || extract(epoch from now())::text || '@futureminds.test',
    '9' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
    crypt('Testpass123!', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}',
    '{"name":"Test Admin","role":"PARENT","consent":true}', now(), now(), '', '', '', '')
  returning id into v_admin_id;

  -- Public signup can never create an ADMIN (by design) — this is the
  -- founder manually granting the first admin account, same as you'd do
  -- for real once.
  update profiles set role = 'ADMIN' where id = v_admin_id;

  raise notice 'STEP 1 ok — created parent=% teacher=% admin=%', v_parent_id, v_teacher_id, v_admin_id;

  -- 2. Teacher fills out their profile (required before they can be matched).
  perform set_config('request.jwt.claims', json_build_object('sub', v_teacher_id)::text, true);
  select * into v_teacher_profile from upsert_teacher_profile(
    p_qualification := 'M.Sc Mathematics', p_subjects := array['Maths'],
    p_time_slot := 'Weekday evenings', p_bank_upi_ref := 'test@upi'
  );
  raise notice 'STEP 2 ok — teacher profile %', v_teacher_profile.display_id;

  -- 3. Parent submits a requirement for a new student.
  perform set_config('request.jwt.claims', json_build_object('sub', v_parent_id)::text, true);
  select * into v_req from submit_requirement(
    p_subject := 'Maths', p_mode := 'Online', p_consent := true,
    p_student_name := 'Test Kid', p_age_grade := 'Grade 6'
  );
  raise notice 'STEP 3 ok — requirement %', v_req.display_id;

  -- 4. Admin creates the match.
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_id)::text, true);
  select * into v_match from create_match(v_req.display_id, v_teacher_profile.display_id, 92);
  raise notice 'STEP 4 ok — match created, display id % (expect FMMATCH...)', match_display_id(v_match);

  -- 5. Admin proposes a demo.
  select * into v_match from propose_demo(v_match.id::text, current_date + 3, 'Weekday evenings');
  raise notice 'STEP 5 ok — demo proposed, status=% display id % (expect FMDEMO...)', v_match.status, match_display_id(v_match);

  -- 6. Parent accepts.
  perform set_config('request.jwt.claims', json_build_object('sub', v_parent_id)::text, true);
  select * into v_match from accept_demo(v_match.id::text);
  raise notice 'STEP 6 ok — parent accepted, status=% (expect still DEMO_PROPOSED, waiting on teacher)', v_match.status;

  -- 7. Teacher accepts -> both true -> should flip to DEMO_SCHEDULED automatically.
  perform set_config('request.jwt.claims', json_build_object('sub', v_teacher_id)::text, true);
  select * into v_match from accept_demo(v_match.id::text);
  raise notice 'STEP 7 ok — teacher accepted, status=% (expect DEMO_SCHEDULED)', v_match.status;

  -- 8. Parent gives final approval -> CONFIRMED, display id becomes FMAPPROVED...
  perform set_config('request.jwt.claims', json_build_object('sub', v_parent_id)::text, true);
  select * into v_match from approve_teacher(v_match.id::text);
  raise notice 'STEP 8 ok — parent approved, status=% display id % (expect FMAPPROVED...)', v_match.status, match_display_id(v_match);

  -- 9. Teacher logs a class taught.
  perform set_config('request.jwt.claims', json_build_object('sub', v_teacher_id)::text, true);
  select * into v_session from log_session(v_match.id::text, current_date, 'Weekday evenings', 500);
  raise notice 'STEP 9 ok — session logged % status=%', v_session.display_id, v_session.status;

  -- 10. Parent confirms it happened.
  perform set_config('request.jwt.claims', json_build_object('sub', v_parent_id)::text, true);
  select * into v_session from confirm_session(v_session.id::text);
  raise notice 'STEP 10 ok — parent confirmed, status=% (expect PARENT_CONFIRMED)', v_session.status;

  -- 11. Admin validates the class.
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_id)::text, true);
  select * into v_session from validate_session(v_session.id::text);
  raise notice 'STEP 11 ok — admin validated, status=% (expect ADMIN_VALIDATED)', v_session.status;

  -- 12. Admin releases payout (20% commission), auto-resolving teacher from the match.
  select * into v_payout from release_payout(p_match_id := v_match.id::text, p_commission_percent := 20);
  raise notice 'STEP 12 ok — payout released: gross=% commission%%=% net=%', v_payout.gross_amount, v_payout.commission_percent, v_payout.amount;

  raise notice '=== ALL 12 STEPS PASSED ===';
end $$;
