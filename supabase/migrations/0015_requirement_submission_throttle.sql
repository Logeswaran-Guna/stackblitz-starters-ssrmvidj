-- Defense-in-depth against a script hammering submit_requirement directly
-- (bypassing the frontend's honeypot/timing checks entirely, since the
-- RPC is reachable by anyone with the anon key once signed in). A real
-- submission calls this once per subject selected (typically 1-5), so the
-- threshold is generous enough to never affect a real family while still
-- capping runaway abuse from a single session.
--
-- This does NOT stop someone from creating a fresh account per
-- submission — that's a materially more expensive attack (a real,
-- distinct email each time) than the realistic threat model here
-- (a headless-browser bot filling the public form), which the frontend's
-- honeypot + minimum-fill-time check is aimed at instead. If that stops
-- being enough, the next tier up is a CAPTCHA (e.g. Cloudflare Turnstile)
-- on the public forms, which needs an account on the client's side to
-- set up.
create or replace function submit_requirement(
  p_subject text,
  p_mode text[],
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
  v_recent_count int;
begin
  if me.role <> 'PARENT' then raise exception 'Only parents can submit requirements'; end if;
  if not p_consent then raise exception 'Consent to be contacted is required'; end if;

  select count(*) into v_recent_count from requirements
    where parent_id = me.id and created_at > now() - interval '10 minutes';
  if v_recent_count >= 15 then
    raise exception 'Too many requirements submitted recently. Please wait a few minutes and try again, or contact us directly if you need to add more.';
  end if;

  return _submit_requirement_for(
    me.id, p_subject, p_mode, p_location, p_schedule_pref, p_pricing_type, p_budget,
    p_preferred_teacher_gender, p_student_id, p_student_name, p_age_grade, p_age, p_gender,
    p_address, p_area_city, p_pincode, p_whatsapp, p_notes, p_prior_tutoring_experience
  );
end;
$$;
