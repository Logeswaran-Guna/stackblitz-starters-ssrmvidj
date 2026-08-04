-- Public storage bucket for teacher profile photos. Public (unlike
-- kyc-documents) since a profile photo is meant to be shown to parents
-- browsing matches, not sensitive like a government ID.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- Anyone can view (bucket is public), but only the owning teacher can
-- upload/replace/delete their own file, stored at "<user_id>/<filename>".
create policy avatars_public_read on storage.objects for select
  using (bucket_id = 'avatars');

create policy avatars_teacher_insert_own on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy avatars_teacher_update_own on storage.objects for update
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy avatars_teacher_delete_own on storage.objects for delete
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
