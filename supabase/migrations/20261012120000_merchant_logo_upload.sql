insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('merchant-logos', 'merchant-logos', true, 5242880, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Merchant owners upload their logos" on storage.objects;
create policy "Merchant owners upload their logos"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'merchant-logos'
  and (storage.foldername(storage.objects.name))[1] is not null
  and exists (
    select 1
    from public.nfc_profiles p
    where p.id::text = (storage.foldername(storage.objects.name))[1]
      and p.owner_id = (select auth.uid())
  )
);
