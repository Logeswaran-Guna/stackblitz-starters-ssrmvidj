-- Admin-uploadable flyer/banner image per course, shown on the public AI &
-- Robotics catalog card. Public bucket (like avatars) since a course flyer
-- is meant to be shown to visitors, not sensitive like KYC documents.

alter table academy_courses add column if not exists image_url text;

insert into storage.buckets (id, name, public)
values ('academy-flyers', 'academy-flyers', true)
on conflict (id) do nothing;

-- Anyone can view (bucket is public); only admins can upload/replace/delete,
-- since a course flyer is admin-managed content, not user-owned like an
-- avatar or KYC document.
create policy academy_flyers_public_read on storage.objects for select
  using (bucket_id = 'academy-flyers');

create policy academy_flyers_admin_insert on storage.objects for insert
  with check (bucket_id = 'academy-flyers' and public.is_admin());

create policy academy_flyers_admin_update on storage.objects for update
  using (bucket_id = 'academy-flyers' and public.is_admin());

create policy academy_flyers_admin_delete on storage.objects for delete
  using (bucket_id = 'academy-flyers' and public.is_admin());

-- Return-column set changes below, so the old signatures must be dropped
-- first (CREATE OR REPLACE can't add columns to an existing RETURNS TABLE).
drop function if exists academy_courses_public();
drop function if exists admin_academy_courses();

-- === Public: course listing for the AI & Robotics page (signed-out too) ===
create or replace function academy_courses_public()
returns table (
  id uuid, display_id text, title text, age_range text, format text,
  description text, duration text, price numeric, status text, image_url text
)
language sql security definer set search_path = public as $$
  select id, display_id, title, age_range, format, description, duration, price, status, image_url
  from academy_courses
  where status in ('OPEN', 'COMING_SOON')
  order by display_order, created_at;
$$;

-- === Admin: full course list (any status) =================================
create or replace function admin_academy_courses()
returns table (
  id uuid, display_id text, title text, age_range text, format text,
  description text, duration text, price numeric, status text, display_order int,
  image_url text, enrollment_count bigint
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
    select c.id, c.display_id, c.title, c.age_range, c.format, c.description, c.duration,
      c.price, c.status, c.display_order, c.image_url,
      count(e.id)
    from academy_courses c
    left join academy_enrollments e on e.course_id = c.id
    group by c.id
    order by c.display_order, c.created_at;
end;
$$;

-- === Admin: create/update a course =========================================
-- Adds p_image_url as a new optional trailing param — CREATE OR REPLACE can
-- extend a function's parameter list as long as new params are at the end
-- and have defaults, so no drop needed here.
create or replace function upsert_academy_course(
  p_id text default null,
  p_title text default null,
  p_age_range text default null,
  p_format text default null,
  p_description text default null,
  p_duration text default null,
  p_price numeric default null,
  p_status text default null,
  p_display_order int default null,
  p_image_url text default null
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
    insert into academy_courses (display_id, title, age_range, format, description, duration, price, status, display_order, image_url)
    values (
      next_daily_id('academy_course_daily', 'FMCOURSE'), trim(p_title), p_age_range, p_format, p_description,
      p_duration, p_price, coalesce(p_status, 'OPEN'), coalesce(p_display_order, 0), p_image_url
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
      display_order = coalesce(p_display_order, display_order),
      image_url = coalesce(p_image_url, image_url)
    where id = v_course.id
    returning * into v_course;
  end if;

  return v_course;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;

grant execute on function academy_courses_public() to anon;
