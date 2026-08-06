-- Encrypts bank/UPI details at rest. Previously teacher_profiles.bank_upi_ref
-- (and its snapshot in payouts.bank_upi_ref) were stored as plain text —
-- readable by anyone with DB access, not just the app. This adds an
-- app-level encryption layer using pgcrypto (already enabled in 0001) so
-- the raw value is never persisted.
--
-- IMPORTANT — one-time manual step required after running this migration,
-- run directly in the Supabase SQL editor (never commit a real key to git):
--
--   insert into app_secrets (key_name, key_value)
--   values ('bank_upi_encryption_key', encode(gen_random_bytes(32), 'base64'))
--   on conflict (key_name) do nothing;
--
-- Until that row exists, encrypt_secret()/decrypt_secret() raise an error
-- rather than silently storing plaintext or a fixed/guessable key.

create table app_secrets (
  key_name text primary key,
  key_value text not null,
  created_at timestamptz not null default now()
);

alter table app_secrets enable row level security;
-- No policies at all: nobody gets a row via PostgREST, even the caller's
-- own service. SECURITY DEFINER functions below read it directly as the
-- table owner, bypassing RLS the same way is_admin() bypasses profiles'.
revoke all on app_secrets from authenticated, anon;

create or replace function _bank_encryption_key()
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_key text;
begin
  select key_value into v_key from app_secrets where key_name = 'bank_upi_encryption_key';
  if v_key is null then
    raise exception 'bank_upi_encryption_key is not set — see 0019_encrypt_bank_details.sql for the one-time setup step';
  end if;
  return v_key;
end;
$$;

-- Marker prefix makes already-encrypted values unambiguous, so decrypt_secret
-- can stay backward-compatible with any legacy plaintext rows written before
-- this migration, without a forced backfill.
create or replace function encrypt_secret(p_plain text)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if p_plain is null or p_plain = '' then
    return p_plain;
  end if;
  return 'ENC1:' || encode(pgp_sym_encrypt(p_plain, _bank_encryption_key()), 'base64');
end;
$$;

create or replace function decrypt_secret(p_stored text)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if p_stored is null or p_stored = '' then
    return p_stored;
  end if;
  if left(p_stored, 5) <> 'ENC1:' then
    return p_stored; -- legacy plaintext row, written before this migration
  end if;
  return pgp_sym_decrypt(decode(substring(p_stored from 6), 'base64'), _bank_encryption_key());
end;
$$;

-- === Encrypt on write: the one shared helper behind both the teacher's own
-- upsert_teacher_profile and admin_upsert_teacher_profile. ===================
create or replace function _upsert_teacher_profile_for(
  p_user_id uuid,
  p_display_id text,
  p_qualification text default null,
  p_experience text default null,
  p_subjects text[] default null,
  p_preferred_locations text[] default null,
  p_teaching_mode text[] default null,
  p_availability text[] default null,
  p_time_slot text default null,
  p_rate_expectation numeric default null,
  p_bank_upi_ref text default null,
  p_address text default null,
  p_area_city text default null,
  p_pincode text default null,
  p_whatsapp text default null,
  p_photo_url text default null,
  p_tutoring_for text[] default null,
  p_boards text[] default null
)
returns teacher_profiles
language plpgsql security definer set search_path = public as $$
declare
  v_profile teacher_profiles;
  v_availability text[] := coalesce(p_availability, case when p_time_slot is not null then array[p_time_slot] else '{}'::text[] end);
  v_bank_upi_ref text := encrypt_secret(p_bank_upi_ref);
begin
  select * into v_profile from teacher_profiles where user_id = p_user_id;

  if v_profile.id is null then
    insert into teacher_profiles (display_id, user_id, qualification, experience, subjects, preferred_locations, teaching_mode, availability, rate_expectation, bank_upi_ref, address, area_city, pincode, whatsapp, kyc_status, photo_url, tutoring_for, boards)
    values (p_display_id, p_user_id, p_qualification, p_experience, coalesce(p_subjects, '{}'), coalesce(p_preferred_locations, '{}'), coalesce(p_teaching_mode, '{}'), v_availability, p_rate_expectation, v_bank_upi_ref, p_address, p_area_city, p_pincode, p_whatsapp, 'PENDING', p_photo_url, coalesce(p_tutoring_for, '{}'), coalesce(p_boards, '{}'))
    returning * into v_profile;
  else
    update teacher_profiles set
      qualification = coalesce(p_qualification, qualification),
      experience = coalesce(p_experience, experience),
      subjects = case when p_subjects is not null and array_length(p_subjects, 1) > 0 then p_subjects else subjects end,
      preferred_locations = case when p_preferred_locations is not null and array_length(p_preferred_locations, 1) > 0 then p_preferred_locations else preferred_locations end,
      teaching_mode = case when p_teaching_mode is not null and array_length(p_teaching_mode, 1) > 0 then p_teaching_mode else teaching_mode end,
      availability = case when array_length(v_availability, 1) > 0 then v_availability else availability end,
      rate_expectation = coalesce(p_rate_expectation, rate_expectation),
      bank_upi_ref = coalesce(v_bank_upi_ref, bank_upi_ref),
      address = coalesce(p_address, address),
      area_city = coalesce(p_area_city, area_city),
      pincode = coalesce(p_pincode, pincode),
      whatsapp = coalesce(p_whatsapp, whatsapp),
      photo_url = coalesce(p_photo_url, photo_url),
      tutoring_for = case when p_tutoring_for is not null and array_length(p_tutoring_for, 1) > 0 then p_tutoring_for else tutoring_for end,
      boards = case when p_boards is not null and array_length(p_boards, 1) > 0 then p_boards else boards end
    where id = v_profile.id
    returning * into v_profile;
  end if;

  return v_profile;
end;
$$;

-- === Decrypt on read: only for the teacher's own eyes (Teacher Profile page).
-- admin_teachers_directory() and release_payout() deliberately keep handling
-- bank_upi_ref as opaque ciphertext — admin never needs to see the raw
-- value, only that one is on file, so it's never decrypted for them. =========
create or replace function my_teacher_profile()
returns table (
  id uuid, display_id text, name text, phone text, email text, qualification text,
  experience text, subjects text[], preferred_locations text[], teaching_mode text[],
  availability text[], rate_expectation numeric, bank_upi_ref text,
  kyc_status text, kyc_document_path text, photo_url text,
  tutoring_for text[], boards text[], rating numeric,
  languages jsonb,
  total_hours numeric, students_trained int, active_batches int,
  rating_avg numeric, rating_count int,
  status entity_status
)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  if me.role <> 'TEACHER' then raise exception 'Teacher only'; end if;
  perform _recompute_status(me.id);

  return query
  select t.id, t.display_id, u.name, u.phone, u.email, t.qualification, t.experience,
    t.subjects, t.preferred_locations, t.teaching_mode, t.availability, t.rate_expectation,
    decrypt_secret(t.bank_upi_ref), t.kyc_status, t.kyc_document_path, t.photo_url,
    t.tutoring_for, t.boards, t.rating,
    coalesce(
      (select jsonb_agg(jsonb_build_object('language', tl.language, 'can_read', tl.can_read, 'can_write', tl.can_write, 'can_speak', tl.can_speak))
       from teacher_languages tl where tl.teacher_id = t.id),
      '[]'::jsonb
    ),
    coalesce((select sum(cs.duration_hours) from class_sessions cs join matches m on m.id = cs.match_id where m.teacher_id = t.id and cs.status <> 'DISPUTED'), 0),
    coalesce((select count(distinct r.student_id) from matches m join requirements r on r.id = m.requirement_id where m.teacher_id = t.id and m.status = 'CONFIRMED'), 0)::int,
    coalesce((select count(*) from matches m where m.teacher_id = t.id and m.status = 'CONFIRMED'), 0)::int,
    (select round(avg(tr.rating), 1) from teacher_reviews tr where tr.teacher_id = t.id),
    coalesce((select count(*) from teacher_reviews tr where tr.teacher_id = t.id), 0)::int,
    u.status
  from teacher_profiles t
  join profiles u on u.id = t.user_id
  where t.user_id = me.id;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
