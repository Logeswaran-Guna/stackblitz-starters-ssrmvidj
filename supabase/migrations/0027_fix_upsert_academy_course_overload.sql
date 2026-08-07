-- Fixes the same class of bug in three places: a later migration extended
-- an existing function's parameter list via CREATE OR REPLACE FUNCTION,
-- which in Postgres does NOT replace a function with a different parameter
-- signature — it creates a second overload. Both versions then stay live;
-- a call naming only parameters common to both is ambiguous and fails with
-- "Could not choose the best candidate function" (PGRST203). A call that
-- happens to include the new-only parameter resolves fine, which is why
-- these went unnoticed for so long.
--
-- 1. upsert_academy_course — introduced in 0024_academy_course_images.sql
--    (added p_image_url). Confirmed live: plain status/price/duration
--    edits from the Academy admin tab broke; flyer uploads (which include
--    p_image_url) did not, masking it until now.
-- 2. release_payout — introduced in 0018_community_pooling.sql (added
--    p_pooling_group_id). Confirmed live: the main admin dashboard's
--    "Release Payout" button (which never passes p_pooling_group_id)
--    broke; Community Pooling's own release-payout call (which does pass
--    it) did not, masking it since 0018 — predates this session.
-- 3. add_requirement_to_pooling_group — introduced in
--    0021_pooling_flat_commission.sql (added p_pool_amount). Not currently
--    triggered (its one call site always passes p_pool_amount), but the
--    stale overload is dropped here too for correctness.
drop function if exists upsert_academy_course(text, text, text, text, text, text, numeric, text, int);
drop function if exists release_payout(text, text, text, numeric);
drop function if exists add_requirement_to_pooling_group(text, text);
