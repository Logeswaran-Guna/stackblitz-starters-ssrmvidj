-- Academy course catalog + enrollment. Previously the AI & Robotics page's
-- tracks/pricing were hardcoded in the page's source — admin couldn't
-- change a price or add a course without a code change, and there was no
-- way for a parent/adult to actually express enrollment interest beyond a
-- mailto link.
--
-- No payment gateway exists yet (same as every other fee in this system),
-- so enrollment stays "tracked, not collected" — a lead admin follows up
-- with to arrange payment manually, not a checkout flow.

create table if not exists academy_courses (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  title text not null,
  age_range text,
  format text,           -- e.g. "Course Package", "Weekend Workshop", "Live Class"
  description text,
  duration text,          -- e.g. "1 term", "2 hours"
  price numeric,           -- nullable — admin fills in once finalized
  status text not null default 'OPEN' check (status in ('OPEN', 'COMING_SOON', 'CLOSED')),
  display_order int not null default 0,
  created_at timestamptz not null default now()
);

-- No login required to enrol — an adult enrolling themselves in Adult &
-- Family AI isn't necessarily a registered parent, and this is a lead
-- capture, not an account-gated action.
create table if not exists academy_enrollments (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  course_id uuid not null references academy_courses(id) on delete cascade,
  enrollee_name text not null,
  student_name text,
  student_age text,
  contact_phone text not null,
  contact_email text,
  notes text,
  status text not null default 'NEW' check (status in ('NEW', 'CONTACTED', 'ENROLLED', 'DECLINED')),
  created_at timestamptz not null default now()
);

create index if not exists idx_academy_enrollments_course on academy_enrollments(course_id);

alter table academy_courses enable row level security;
alter table academy_enrollments enable row level security;

-- No policies at all — every read/write goes through the RPCs below, same
-- as the rest of this schema.
revoke all on academy_courses, academy_enrollments from authenticated, anon;

-- === Public: course listing for the AI & Robotics page (signed-out too) ===
create or replace function academy_courses_public()
returns table (
  id uuid, display_id text, title text, age_range text, format text,
  description text, duration text, price numeric, status text
)
language sql security definer set search_path = public as $$
  select id, display_id, title, age_range, format, description, duration, price, status
  from academy_courses
  where status in ('OPEN', 'COMING_SOON')
  order by display_order, created_at;
$$;

-- === Public: submit enrollment interest (signed-out too) =================
create or replace function submit_academy_enrollment(
  p_course_id text,
  p_enrollee_name text,
  p_contact_phone text,
  p_contact_email text default null,
  p_student_name text default null,
  p_student_age text default null,
  p_notes text default null
)
returns academy_enrollments
language plpgsql security definer set search_path = public as $$
declare
  v_course academy_courses;
  v_enrollment academy_enrollments;
begin
  if p_enrollee_name is null or trim(p_enrollee_name) = '' then
    raise exception 'Name is required';
  end if;
  if p_contact_phone is null or trim(p_contact_phone) = '' then
    raise exception 'Contact phone is required';
  end if;

  select * into v_course from academy_courses
  where (id::text = p_course_id or display_id = p_course_id) and status = 'OPEN';
  if v_course.id is null then
    raise exception 'Course not found or not currently open for enrollment';
  end if;

  insert into academy_enrollments (display_id, course_id, enrollee_name, student_name, student_age, contact_phone, contact_email, notes)
  values (next_daily_id('academy_enroll_daily', 'FMENROLL'), v_course.id, trim(p_enrollee_name), p_student_name, p_student_age, trim(p_contact_phone), p_contact_email, p_notes)
  returning * into v_enrollment;

  return v_enrollment;
end;
$$;

-- === Admin: full course list (any status) =================================
create or replace function admin_academy_courses()
returns table (
  id uuid, display_id text, title text, age_range text, format text,
  description text, duration text, price numeric, status text, display_order int,
  enrollment_count bigint
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
    select c.id, c.display_id, c.title, c.age_range, c.format, c.description, c.duration,
      c.price, c.status, c.display_order,
      count(e.id)
    from academy_courses c
    left join academy_enrollments e on e.course_id = c.id
    group by c.id
    order by c.display_order, c.created_at;
end;
$$;

-- === Admin: create/update a course =========================================
create or replace function upsert_academy_course(
  p_id text default null,
  p_title text default null,
  p_age_range text default null,
  p_format text default null,
  p_description text default null,
  p_duration text default null,
  p_price numeric default null,
  p_status text default null,
  p_display_order int default null
)
returns academy_courses
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_course academy_courses;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  if p_id is not null then
    select * into v_course from academy_courses where id::text = p_id or display_id = p_id;
  end if;

  if v_course.id is null then
    if p_title is null or trim(p_title) = '' then raise exception 'Title is required'; end if;
    insert into academy_courses (display_id, title, age_range, format, description, duration, price, status, display_order)
    values (
      next_daily_id('academy_course_daily', 'FMCOURSE'), trim(p_title), p_age_range, p_format, p_description,
      p_duration, p_price, coalesce(p_status, 'OPEN'), coalesce(p_display_order, 0)
    )
    returning * into v_course;
  else
    update academy_courses set
      title = coalesce(p_title, title),
      age_range = coalesce(p_age_range, age_range),
      format = coalesce(p_format, format),
      description = coalesce(p_description, description),
      duration = coalesce(p_duration, duration),
      price = coalesce(p_price, price),
      status = coalesce(p_status, status),
      display_order = coalesce(p_display_order, display_order)
    where id = v_course.id
    returning * into v_course;
  end if;

  return v_course;
end;
$$;

-- === Admin: enrollment queue ================================================
create or replace function admin_academy_enrollments()
returns table (
  id uuid, display_id text, course_id uuid, course_title text,
  enrollee_name text, student_name text, student_age text,
  contact_phone text, contact_email text, notes text, status text, created_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
    select e.id, e.display_id, e.course_id, c.title,
      e.enrollee_name, e.student_name, e.student_age,
      e.contact_phone, e.contact_email, e.notes, e.status, e.created_at
    from academy_enrollments e
    join academy_courses c on c.id = e.course_id
    order by e.created_at desc;
end;
$$;

create or replace function set_academy_enrollment_status(p_id text, p_status text)
returns academy_enrollments
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_enrollment academy_enrollments;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  if p_status not in ('NEW', 'CONTACTED', 'ENROLLED', 'DECLINED') then
    raise exception 'Invalid status';
  end if;

  update academy_enrollments set status = p_status
  where id::text = p_id or display_id = p_id
  returning * into v_enrollment;

  if v_enrollment.id is null then raise exception 'Enrollment not found'; end if;
  return v_enrollment;
end;
$$;

-- Seed the 4 tracks already described on the AI & Robotics page. Price is
-- left blank intentionally — fill in via the admin dashboard once finalized.
insert into academy_courses (display_id, title, age_range, format, description, duration, status, display_order) values
  ('FMCOURSE-SEED-01', 'Robotics Starter', 'Ages 6-9', 'Course Package', 'Snap-together kits, block-based coding, sensors & motors, demo day each term.', '1 term', 'OPEN', 1),
  ('FMCOURSE-SEED-02', 'Junior AI Coders', 'Ages 10-13', 'Course Package', 'Intro to Python & logic, how AI models "learn", responsible AI usage, build a chatbot.', '1 term', 'OPEN', 2),
  ('FMCOURSE-SEED-03', 'AI Builders - Teen', 'Ages 14-17', 'Course Package', 'Machine learning concepts, an applied AI/Robotics capstone project, ethics & careers.', '1 term', 'OPEN', 3),
  ('FMCOURSE-SEED-04', 'Adult & Family AI', 'All ages', 'Course Package', 'Workplace AI, AI productivity & automation tools, family AI literacy, safe AI usage, and AI-powered parenting.', '1 term', 'OPEN', 4)
on conflict (display_id) do nothing;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;

-- The AI & Robotics page and its enrollment form need to work for
-- signed-out visitors too.
grant execute on function academy_courses_public() to anon;
grant execute on function submit_academy_enrollment(text, text, text, text, text, text, text) to anon;
