-- Catch-up for the developer-requirements-doc alignment pass: new fields
-- (preferred teacher gender, prior tutoring experience, KYC document),
-- the KYC storage bucket, and the functions whose signature/return columns
-- changed as a result.

alter table students add column if not exists prior_tutoring_experience text;
alter table requirements add column if not exists preferred_teacher_gender text;
alter table teacher_profiles add column if not exists kyc_document_path text;

drop function if exists submit_requirement(text, text, boolean, text, text, text, numeric, text, text, text, int, text, text, text, text, text, text);
drop function if exists admin_requirements_queue();
drop function if exists admin_teachers_directory(text);

-- === submit_requirement (new params: preferred_teacher_gender, prior_tutoring_experience) ===
create or replace function submit_requirement(
  p_subject text,
  p_mode text,
  p_consent boolean,
  p_location text default null,
  p_schedule_pref text default null,
  p_pricing_type text default null,
  p_budget numeric default null,
  p_preferred_teacher_gender text default null,
  p_student_id text default null,
  p_student_name text default null,
  p_age_grade text default null,
  p_age int default null,
  p_gender text default null,
  p_address text default null,
  p_area_city text default null,
  p_pincode text default null,
  p_whatsapp text default null,
  p_notes text default null,
  p_prior_tutoring_experience text default null
)
returns requirements
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_student students;
  v_req requirements;
  v_count int;
begin
  if me.role <> 'PARENT' then raise exception 'Only parents can submit requirements'; end if;
  if not p_consent then raise exception 'Consent to be contacted is required'; end if;
  if p_subject is null or p_mode is null then raise exception 'Subject and mode are required'; end if;

  if p_student_id is not null then
    v_student := find_student(p_student_id, me.id);
    if v_student.id is null then raise exception 'Student not found for your account'; end if;
    update students set
      address = coalesce(p_address, address),
      area_city = coalesce(p_area_city, area_city),
      pincode = coalesce(p_pincode, pincode),
      whatsapp = coalesce(p_whatsapp, whatsapp),
      notes = coalesce(p_notes, notes),
      prior_tutoring_experience = coalesce(p_prior_tutoring_experience, prior_tutoring_experience)
    where id = v_student.id
    returning * into v_student;
  elsif p_student_name is not null or p_age_grade is not null then
    select count(*) into v_count from students where parent_id = me.id;
    if v_count >= 4 then
      raise exception 'You can register up to 4 students per parent account. To add a subject for an existing student instead, pass their Student ID.';
    end if;
    insert into students (display_id, parent_id, student_name, age_grade, age, gender, address, area_city, pincode, whatsapp, notes, prior_tutoring_experience)
    values (next_daily_id('student_daily', 'FMSTU'), me.id, p_student_name, p_age_grade, p_age, p_gender, p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience)
    returning * into v_student;
  end if;

  insert into requirements (display_id, parent_id, student_id, subject, mode, location, schedule_pref, pricing_type, budget, preferred_teacher_gender)
  values (next_daily_id('requirement_daily', 'FMREQ'), me.id, v_student.id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget, p_preferred_teacher_gender)
  returning * into v_req;

  return v_req;
end;
$$;

-- === admin_requirements_queue (adds preferred_teacher_gender) =============
create or replace function admin_requirements_queue()
returns table (
  id uuid, display_id text, subject text, mode text, location text, schedule_pref text,
  budget numeric, preferred_teacher_gender text, status requirement_status, created_at timestamptz,
  parent_display_id text, parent_name text, parent_phone text,
  student_display_id text, student_name text, student_grade text,
  match_id uuid, match_label text, match_status match_status, match_score numeric,
  demo_date date, demo_time_slot text, parent_accepted_demo boolean, teacher_accepted_demo boolean,
  teacher_id uuid, teacher_display_id text, teacher_name text
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
  select r.id, r.display_id, r.subject, r.mode, r.location, r.schedule_pref, r.budget, r.preferred_teacher_gender, r.status, r.created_at,
    p.display_id, p.name, p.phone,
    s.display_id, s.student_name, s.age_grade,
    bm.id, case when bm.id is not null then match_display_id(bm) else null end, bm.status, bm.match_score,
    bm.demo_date, bm.demo_time_slot, bm.parent_accepted_demo, bm.teacher_accepted_demo,
    tp.id, tp.display_id, tu.name
  from requirements r
  join profiles p on p.id = r.parent_id
  left join students s on s.id = r.student_id
  left join lateral (
    select m.* from matches m
    where m.requirement_id = r.id and m.status <> 'DECLINED'
    order by (m.status = 'CONFIRMED') desc, m.created_at desc
    limit 1
  ) bm on true
  left join teacher_profiles tp on tp.id = bm.teacher_id
  left join profiles tu on tu.id = tp.user_id
  order by r.created_at desc;
end;
$$;

-- === admin_teachers_directory (adds kyc_document_path) ====================
create or replace function admin_teachers_directory(p_subject text default null)
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text,
  availability text[], rate_expectation numeric,
  bank_upi_ref text, kyc_status text, kyc_document_path text, rating numeric
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
  select t.id, t.display_id, u.name, u.phone, u.email, t.qualification, t.experience,
    t.subjects, t.preferred_locations, t.teaching_mode, t.availability, t.rate_expectation,
    t.bank_upi_ref, t.kyc_status, t.kyc_document_path, t.rating
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where p_subject is null or p_subject = any(t.subjects);
end;
$$;

-- === new: teacher records where their KYC doc landed in storage ===========
create or replace function set_kyc_document(p_path text)
returns teacher_profiles
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_profile teacher_profiles;
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;

  update teacher_profiles
  set kyc_document_path = p_path, kyc_status = 'PENDING'
  where user_id = me.id
  returning * into v_profile;

  if v_profile.id is null then raise exception 'Complete your teacher profile before uploading KYC documents'; end if;
  return v_profile;
end;
$$;

-- === new: admin approves/rejects a teacher's KYC document =================
create or replace function set_teacher_kyc_status(p_teacher_id text, p_status text)
returns teacher_profiles
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_teacher teacher_profiles;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  if p_status not in ('APPROVED', 'REJECTED', 'PENDING') then
    raise exception 'Status must be APPROVED, REJECTED, or PENDING';
  end if;

  v_teacher := find_teacher(p_teacher_id);
  if v_teacher.id is null then raise exception 'Teacher profile not found'; end if;

  update teacher_profiles set kyc_status = p_status where id = v_teacher.id returning * into v_teacher;
  return v_teacher;
end;
$$;

-- === KYC storage bucket + policies =========================================
insert into storage.buckets (id, name, public)
values ('kyc-documents', 'kyc-documents', false)
on conflict (id) do nothing;

drop policy if exists kyc_teacher_insert_own on storage.objects;
drop policy if exists kyc_teacher_select_own on storage.objects;
drop policy if exists kyc_teacher_update_own on storage.objects;
drop policy if exists kyc_teacher_delete_own on storage.objects;

create policy kyc_teacher_insert_own on storage.objects for insert
  with check (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy kyc_teacher_select_own on storage.objects for select
  using (
    bucket_id = 'kyc-documents'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin()
    )
  );

create policy kyc_teacher_update_own on storage.objects for update
  using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy kyc_teacher_delete_own on storage.objects for delete
  using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Re-grant execute (DROP FUNCTION removed grants on the dropped ones).
revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
