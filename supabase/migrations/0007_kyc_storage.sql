-- Private storage bucket for tutor KYC documents (Government ID upload),
-- per developer requirements spec 4.4: "required before a tutor is matched
-- with families". Files are stored at "<user_id>/<filename>" so ownership
-- can be checked from the path alone.
insert into storage.buckets (id, name, public)
values ('kyc-documents', 'kyc-documents', false)
on conflict (id) do nothing;

-- A teacher can upload/read/replace only files under their own user_id
-- folder; nothing here is public. Admins can read every file (to review
-- KYC submissions); nobody else has any access at all.
create policy kyc_teacher_insert_own on storage.objects for insert
  with check (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy kyc_teacher_select_own on storage.objects for select
  using (
    bucket_id = 'kyc-documents'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin()
    )
  );

create policy kyc_teacher_update_own on storage.objects for update
  using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy kyc_teacher_delete_own on storage.objects for delete
  using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
