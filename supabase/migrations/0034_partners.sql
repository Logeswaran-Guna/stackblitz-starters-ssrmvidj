-- Admin-managed "trusted partners" shown on the homepage marquee
-- (app/components/Partners.tsx) — previously 3 hardcoded logos. Same
-- shape as 0024_academy_course_images.sql: a public storage bucket for
-- the logo image, a status-gated table, a public read RPC and an admin
-- CRUD RPC.
--
-- Three statuses, not two:
--   VISIBLE  — shown on the public site.
--   DISABLED — hidden from the public site, stays in place in the admin
--              list (a temporary pause, not a removal).
--   REMOVED  — hidden from the public site AND sorted to the very end of
--              the admin list (soft-delete: recoverable, but out of the
--              way — "goes to the last page" if the admin has many).
-- There is no hard-delete RPC; REMOVED is as far as it goes.

create table partners (
  id uuid primary key default gen_random_uuid(),
  display_id text unique not null,
  name text not null,
  location text,
  logo_url text,
  status text not null default 'VISIBLE' check (status in ('VISIBLE', 'DISABLED', 'REMOVED')),
  display_order int not null default 0,
  created_at timestamptz not null default now()
);

alter table partners enable row level security;
revoke all on partners from authenticated, anon;

-- Carries forward the 3 sibling businesses that were previously hardcoded
-- into Partners.tsx as hand-drawn SVG logos, so the marquee isn't empty
-- the moment this migration lands. No location is guessed — leave it
-- blank rather than invent one; the admin can fill it in, and upload a
-- real logo image, from the new Partners tab.
insert into partners (display_id, name, display_order)
values
  (next_daily_id('partner_daily', 'FMPARTNER'), 'FM Pre Schools', 1),
  (next_daily_id('partner_daily', 'FMPARTNER'), 'FM Academy', 2),
  (next_daily_id('partner_daily', 'FMPARTNER'), 'Taprootz Technologies', 3);

insert into storage.buckets (id, name, public)
values ('partner-logos', 'partner-logos', true)
on conflict (id) do nothing;

create policy partner_logos_public_read on storage.objects for select
  using (bucket_id = 'partner-logos');

create policy partner_logos_admin_insert on storage.objects for insert
  with check (bucket_id = 'partner-logos' and public.is_admin());

create policy partner_logos_admin_update on storage.objects for update
  using (bucket_id = 'partner-logos' and public.is_admin());

create policy partner_logos_admin_delete on storage.objects for delete
  using (bucket_id = 'partner-logos' and public.is_admin());

-- === Public: homepage marquee (signed-out too) =============================
create or replace function partners_public()
returns table (id uuid, name text, location text, logo_url text)
language sql security definer set search_path = public as $$
  select id, name, location, logo_url
  from partners
  where status = 'VISIBLE'
  order by display_order, created_at;
$$;

-- === Admin: full partner list (any status), REMOVED sorted last ===========
create or replace function admin_partners()
returns setof partners
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;

  return query
    select * from partners
    order by (status = 'REMOVED'), display_order, created_at;
end;
$$;

-- === Admin: create/update a partner =========================================
create or replace function upsert_partner(
  p_id text default null,
  p_name text default null,
  p_location text default null,
  p_logo_url text default null,
  p_status text default null,
  p_display_order int default null
)
returns partners
language plpgsql security definer set search_path = public as $$
declare
  me profiles := current_profile();
  v_partner partners;
begin
  if me.role <> 'ADMIN' then raise exception 'Admin only'; end if;
  if p_status is not null and p_status not in ('VISIBLE', 'DISABLED', 'REMOVED') then
    raise exception 'Invalid status';
  end if;

  if p_id is not null then
    select * into v_partner from partners where id::text = p_id or display_id = p_id;
  end if;

  if v_partner.id is null then
    if p_name is null or trim(p_name) = '' then raise exception 'Name is required'; end if;
    insert into partners (display_id, name, location, logo_url, status, display_order)
    values (
      next_daily_id('partner_daily', 'FMPARTNER'), trim(p_name), p_location, p_logo_url,
      coalesce(p_status, 'VISIBLE'), coalesce(p_display_order, 0)
    )
    returning * into v_partner;
  else
    update partners set
      name = coalesce(p_name, name),
      location = coalesce(p_location, location),
      logo_url = coalesce(p_logo_url, logo_url),
      status = coalesce(p_status, status),
      display_order = coalesce(p_display_order, display_order)
    where id = v_partner.id
    returning * into v_partner;
  end if;

  return v_partner;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;

grant execute on function partners_public() to anon;
