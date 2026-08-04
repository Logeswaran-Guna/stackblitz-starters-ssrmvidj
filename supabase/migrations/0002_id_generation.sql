-- Friendly-ID system, ported from src/idgen.js.
-- Internal `id` (uuid) never changes. These functions produce the DISPLAY
-- id that people actually see/type/paste.

-- Replaces the in-memory data.counters object with a real table so
-- concurrent requests get atomic, gap-free sequence numbers.
create table id_counters (
  bucket_key text not null,
  period text not null,      -- 'YYMMDD' for daily buckets, 'YY' for the match bucket
  seq int not null default 0,
  primary key (bucket_key, period)
);

-- Daily-reset IDs: students, teachers, parents, requirements, attendance.
-- Format: FMSTU260802-01  (prefix + YYMMDD + 2-digit daily sequence)
create or replace function next_daily_id(p_bucket text, p_prefix text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stamp text := to_char(now(), 'YYMMDD');
  v_seq int;
begin
  insert into id_counters (bucket_key, period, seq)
  values (p_bucket, v_stamp, 1)
  on conflict (bucket_key, period)
  do update set seq = id_counters.seq + 1
  returning seq into v_seq;

  return p_prefix || v_stamp || '-' || lpad(v_seq::text, 2, '0');
end;
$$;

-- Yearly-reset (year, seq) pair for matches — same pair survives
-- PROPOSED -> DEMO -> CONFIRMED; only the prefix around it changes.
create or replace function next_match_seq()
returns table (id_year int, id_seq int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year text := to_char(now(), 'YY');
  v_seq int;
begin
  insert into id_counters (bucket_key, period, seq)
  values ('match', v_year, 1)
  on conflict (bucket_key, period)
  do update set seq = id_counters.seq + 1
  returning seq into v_seq;

  id_year := v_year::int;
  id_seq := v_seq;
  return next;
end;
$$;

-- Mirrors idgen.js's matchDisplayId(): PROPOSED -> FMMATCH, DEMO_PROPOSED /
-- DEMO_SCHEDULED -> FMDEMO, CONFIRMED -> FMAPPROVED, and frozen_display_id
-- wins outright once a match is DECLINED.
create or replace function match_display_id(m matches)
returns text
language plpgsql
stable
as $$
declare
  v_num text;
begin
  if m.frozen_display_id is not null then
    return m.frozen_display_id;
  end if;

  v_num := lpad(m.id_year::text, 2, '0') || '-' || lpad(m.id_seq::text, 5, '0');

  if m.status = 'CONFIRMED' then
    return 'FMAPPROVED' || v_num;
  elsif m.status in ('DEMO_PROPOSED', 'DEMO_SCHEDULED') then
    return 'FMDEMO' || v_num;
  else
    return 'FMMATCH' || v_num;
  end if;
end;
$$;

-- resolve*-style helpers: every :id param in the old API accepted EITHER
-- the internal uuid or the current display id. These do the same lookup.
create or replace function find_student(p_id_or_display text, p_parent_id uuid)
returns students language sql stable as $$
  select * from students
  where (id::text = p_id_or_display or display_id = p_id_or_display)
    and parent_id = p_parent_id
  limit 1;
$$;

create or replace function find_requirement(p_id_or_display text)
returns requirements language sql stable as $$
  select * from requirements
  where id::text = p_id_or_display or display_id = p_id_or_display
  limit 1;
$$;

create or replace function find_teacher(p_id_or_display text)
returns teacher_profiles language sql stable as $$
  select * from teacher_profiles
  where id::text = p_id_or_display or display_id = p_id_or_display
  limit 1;
$$;

create or replace function find_match(p_id_or_display text)
returns matches language sql stable as $$
  select m.* from matches m
  where m.id::text = p_id_or_display or match_display_id(m) = p_id_or_display
  limit 1;
$$;

create or replace function find_session(p_id_or_display text)
returns class_sessions language sql stable as $$
  select * from class_sessions
  where id::text = p_id_or_display or display_id = p_id_or_display
  limit 1;
$$;
