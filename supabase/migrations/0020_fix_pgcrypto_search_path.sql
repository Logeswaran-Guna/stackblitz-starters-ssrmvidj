-- Fixes "function pgp_sym_encrypt(text, text) does not exist" from
-- 0019_encrypt_bank_details.sql. Supabase installs pgcrypto into the
-- `extensions` schema, not `public` — the ad hoc gen_random_bytes() call
-- worked fine in the SQL editor (whose session search_path includes
-- extensions by default), but encrypt_secret()/decrypt_secret() explicitly
-- set search_path = public only, which hides it. Adding extensions to
-- their search_path fixes this without loosening anything else.

create or replace function encrypt_secret(p_plain text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_plain is null or p_plain = '' then
    return p_plain;
  end if;
  return 'ENC1:' || encode(pgp_sym_encrypt(p_plain, _bank_encryption_key()), 'base64');
end;
$$;

create or replace function decrypt_secret(p_stored text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_stored is null or p_stored = '' then
    return p_stored;
  end if;
  if left(p_stored, 5) <> 'ENC1:' then
    return p_stored; -- legacy plaintext row, written before 0019
  end if;
  return pgp_sym_decrypt(decode(substring(p_stored from 6), 'base64'), _bank_encryption_key());
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
