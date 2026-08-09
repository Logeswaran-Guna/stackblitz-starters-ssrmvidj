-- Adds a per-row is_unread flag to my_notifications() so the bell dropdown
-- can show which specific notifications are new, not just an aggregate
-- count on the bell icon. Previously the badge count came from a separate
-- RPC (my_unread_notification_count()) computed independently from the
-- list — same underlying logic, but two separate queries that could in
-- principle disagree. Computing is_unread in the same query the list
-- already uses removes that risk entirely; the frontend now derives the
-- badge count by counting is_unread rows instead of a second round trip.
--
-- RETURNS TABLE column list is changing, so the old signature must be
-- dropped first (same reasoning as every prior RETURNS TABLE change this
-- project has made).
drop function if exists my_notifications();

create or replace function my_notifications()
returns table (id uuid, display_id text, scope text, title text, body text, created_at timestamptz, is_unread boolean)
language plpgsql security definer set search_path = public as $$
declare me profiles := current_profile();
begin
  return query
    select n.id, n.display_id, 'GENERAL'::text, n.title, n.body, n.created_at,
      n.created_at > coalesce(me.notifications_last_seen_at, 'epoch'::timestamptz)
    from notifications n
    where n.audience = 'GENERAL'
    union all
    select n.id, n.display_id, 'PERSONAL'::text, n.title, n.body, n.created_at,
      n.created_at > coalesce(me.notifications_last_seen_at, 'epoch'::timestamptz)
    from notifications n
    where n.audience = me.role::text
      and (n.target_profile_id is null or n.target_profile_id = me.id)
    order by created_at desc
    limit 50;
end;
$$;

revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to authenticated;
grant execute on function general_notifications() to anon;
