-- Run this ONCE in the Supabase SQL Editor, after schema.sql.
-- It creates a bucket called "media" for photos and videos people attach to posts.
-- Anyone signed in can upload only into their own folder (named after their user id) and delete only their own files.
-- The bucket is public-read so images load easily; file names are random, so they can't be guessed.
-- (Before a public launch, move to private files with signed links, and add automatic scanning of uploads.)
insert into storage.buckets (id, name, public) values ('media', 'media', true) on conflict (id) do nothing;

create policy "media: upload into your own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "media: delete your own files" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
