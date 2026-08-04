-- Edge-case test: proves the two trickiest rules in the matching state
-- machine actually hold.
--   A) Once a demo is DECLINED, the display id freezes forever and the
--      match can never be reopened — a fresh propose_demo on it must fail.
--   B) Two matches for the SAME teacher on the SAME date + time slot can't
--      both get a demo proposed — the second one must be rejected.
do $$
declare
  v_parent_id uuid;
  v_teacher_id uuid;
  v_admin_id uuid;
  v_teacher_profile teacher_profiles;
  v_req1 requirements;
  v_req2 requirements;
  v_req3 requirements;
  v_match1 matches;
  v_match2 matches;
  v_match3 matches;
  v_frozen_before text;
  v_frozen_after text;
  v_a3_wrongly_succeeded boolean := false;
  v_b2_wrongly_succeeded boolean := false;
begin
  -- Seed fresh test users, same pattern as the main smoke test.
  insert into auth.users (instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'edge.parent.' || extract(epoch from now())::text || '@futureminds.test',
    '9' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
    crypt('Testpass123!', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}',
    '{"name":"Edge Parent","role":"PARENT","consent":true}', now(), now(), '', '', '', '')
  returning id into v_parent_id;

  insert into auth.users (instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'edge.teacher.' || extract(epoch from now())::text || '@futureminds.test',
    '9' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
    crypt('Testpass123!', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}',
    '{"name":"Edge Teacher","role":"TEACHER","consent":true}', now(), now(), '', '', '', '')
  returning id into v_teacher_id;

  insert into auth.users (instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'edge.admin.' || extract(epoch from now())::text || '@futureminds.test',
    '9' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
    crypt('Testpass123!', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}',
    '{"name":"Edge Admin","role":"PARENT","consent":true}', now(), now(), '', '', '', '')
  returning id into v_admin_id;

  update profiles set role = 'ADMIN' where id = v_admin_id;
  raise notice 'Seeded parent=% teacher=% admin=%', v_parent_id, v_teacher_id, v_admin_id;

  perform set_config('request.jwt.claims', json_build_object('sub', v_teacher_id)::text, true);
  select * into v_teacher_profile from upsert_teacher_profile(
    p_qualification := 'B.Ed', p_subjects := array['Science'],
    p_time_slot := 'Weekday evenings', p_bank_upi_ref := 'edge@upi'
  );

  perform set_config('request.jwt.claims', json_build_object('sub', v_parent_id)::text, true);
  select * into v_req1 from submit_requirement(
    p_subject := 'Science', p_mode := 'Online', p_consent := true,
    p_student_name := 'Edge Kid', p_age_grade := 'Grade 7'
  );
  -- req2 and req3 reuse the same student (second/third subject for them) —
  -- keeps us under the 4-student cap regardless of how many times this runs.
  select * into v_req2 from submit_requirement(
    p_subject := 'Maths', p_mode := 'Online', p_consent := true,
    p_student_id := v_req1.student_id::text
  );
  select * into v_req3 from submit_requirement(
    p_subject := 'English', p_mode := 'Online', p_consent := true,
    p_student_id := v_req1.student_id::text
  );

  ------------------------------------------------------------------
  -- EDGE CASE A: decline freezes the display id; match can't reopen
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_id)::text, true);
  select * into v_match1 from create_match(v_req1.display_id, v_teacher_profile.display_id, 80);
  select * into v_match1 from propose_demo(v_match1.id::text, current_date + 5, 'Weekday evenings');
  v_frozen_before := match_display_id(v_match1);
  raise notice 'A1 ok — demo proposed, display id % (expect FMDEMO...)', v_frozen_before;

  perform set_config('request.jwt.claims', json_build_object('sub', v_teacher_id)::text, true);
  select * into v_match1 from decline_demo(v_match1.id::text, 'Schedule conflict');
  v_frozen_after := match_display_id(v_match1);
  raise notice 'A2 ok — teacher declined: status=% frozen_id=% dead=% (expect DECLINED / same %  / true)',
    v_match1.status, v_frozen_after, v_match1.dead, v_frozen_before;

  if v_frozen_after <> v_frozen_before then
    raise exception 'A2 FAILED — display id changed after decline (% -> %), it should have stayed frozen', v_frozen_before, v_frozen_after;
  end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin_id)::text, true);
    perform propose_demo(v_match1.id::text, current_date + 6, 'Weekday evenings');
    v_a3_wrongly_succeeded := true;
  exception when others then
    raise notice 'A3 ok — re-proposing on a DECLINED match was correctly rejected: %', sqlerrm;
  end;
  if v_a3_wrongly_succeeded then
    raise exception 'A3 FAILED — a DECLINED match accepted a new demo proposal; it should have been rejected';
  end if;

  ------------------------------------------------------------------
  -- EDGE CASE B: same teacher + same date + same slot = blocked
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin_id)::text, true);
  select * into v_match2 from create_match(v_req2.display_id, v_teacher_profile.display_id, 85);
  select * into v_match2 from propose_demo(v_match2.id::text, current_date + 7, 'Weekday evenings');
  raise notice 'B1 ok — first booking on %, "Weekday evenings" succeeded, display id %', current_date + 7, match_display_id(v_match2);

  select * into v_match3 from create_match(v_req3.display_id, v_teacher_profile.display_id, 70);
  begin
    perform propose_demo(v_match3.id::text, current_date + 7, 'Weekday evenings');
    v_b2_wrongly_succeeded := true;
  exception when others then
    raise notice 'B2 ok — double-booking was correctly rejected: %', sqlerrm;
  end;
  if v_b2_wrongly_succeeded then
    raise exception 'B2 FAILED — a same-teacher/same-date/same-slot double booking was accepted; it should have been rejected';
  end if;

  raise notice '=== EDGE CASE TESTS COMPLETE, ALL CHECKS PASSED ===';
end $$;
