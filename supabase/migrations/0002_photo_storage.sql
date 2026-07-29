-- Photo blobs live in Storage, not in the record stream.
--
-- A stored meal photo is roughly 0.5–1 MB (2048 px long edge, JPEG q0.84) plus
-- a 480 px thumbnail. Carrying those through the same delta-sync path as
-- ratings and comparisons is what made the previous CloudKit mirror slow and
-- fragile. Here a photo's *metadata* travels as an ordinary encrypted record
-- while its bytes are uploaded once to a private bucket and fetched lazily.
--
-- Object key convention: <circle_id>/<photo_id>.full and <circle_id>/<photo_id>.thumb
-- The first path segment is the circle, which is what the policies authorize on.
-- Bytes are AES-GCM sealed with the same per-circle key used for records, so
-- the bucket holds ciphertext even though it is already private.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'circle-photos',
    'circle-photos',
    false,
    20971520, -- 20 MB ceiling; a sealed 2048 px JPEG is far below this
    array['application/octet-stream']
)
on conflict (id) do update
set public             = excluded.public,
    file_size_limit    = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- storage.objects already has RLS enabled by Supabase.

drop policy if exists circle_photos_select on storage.objects;
create policy circle_photos_select on storage.objects
    for select to authenticated
    using (
        bucket_id = 'circle-photos'
        and private.can_access_circle_storage(((storage.foldername(name))[1])::uuid)
    );

drop policy if exists circle_photos_insert on storage.objects;
create policy circle_photos_insert on storage.objects
    for insert to authenticated
    with check (
        bucket_id = 'circle-photos'
        and private.is_circle_member(((storage.foldername(name))[1])::uuid)
    );

drop policy if exists circle_photos_update on storage.objects;
create policy circle_photos_update on storage.objects
    for update to authenticated
    using (
        bucket_id = 'circle-photos'
        and private.is_circle_member(((storage.foldername(name))[1])::uuid)
    )
    with check (
        bucket_id = 'circle-photos'
        and private.is_circle_member(((storage.foldername(name))[1])::uuid)
    );

drop policy if exists circle_photos_delete on storage.objects;
create policy circle_photos_delete on storage.objects
    for delete to authenticated
    using (
        bucket_id = 'circle-photos'
        and private.can_access_circle_storage(((storage.foldername(name))[1])::uuid)
    );
