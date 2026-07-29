-- Keep recursive RLS helpers SECURITY DEFINER, but move them out of the public
-- schema so PostgREST cannot expose them as user-callable RPC endpoints.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create or replace function private.is_circle_member(target uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select exists (
        select 1
        from public.circle_members m
        join public.circles c on c.id = m.circle_id
        where m.circle_id = target
          and m.user_id = auth.uid()
          and c.deleting_at is null
    );
$$;

create or replace function private.is_circle_owner(target uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select exists (
        select 1
        from public.circles c
        where c.id = target
          and c.owner_id = auth.uid()
    );
$$;

create or replace function private.can_access_circle_storage(target uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select private.is_circle_owner(target) or private.is_circle_member(target);
$$;

revoke all on function private.is_circle_member(uuid) from public;
revoke all on function private.is_circle_owner(uuid) from public;
revoke all on function private.can_access_circle_storage(uuid) from public;
grant execute on function private.is_circle_member(uuid) to authenticated;
grant execute on function private.is_circle_owner(uuid) to authenticated;
grant execute on function private.can_access_circle_storage(uuid) to authenticated;

drop policy if exists circles_select on public.circles;
create policy circles_select on public.circles
    for select to authenticated
    using (private.is_circle_member(id) or owner_id = (select auth.uid()));

drop policy if exists circle_members_select on public.circle_members;
create policy circle_members_select on public.circle_members
    for select to authenticated
    using (private.is_circle_member(circle_id) or private.is_circle_owner(circle_id));

drop policy if exists circle_members_delete on public.circle_members;
create policy circle_members_delete on public.circle_members
    for delete to authenticated
    using (
        (user_id = (select auth.uid()) and role = 'member')
        or (
            private.is_circle_owner(circle_id)
            and user_id <> (select auth.uid())
            and role = 'member'
        )
    );

drop policy if exists circle_invites_select on public.circle_invites;
create policy circle_invites_select on public.circle_invites
    for select to authenticated
    using (private.is_circle_owner(circle_id));

drop policy if exists circle_invites_insert on public.circle_invites;
create policy circle_invites_insert on public.circle_invites
    for insert to authenticated
    with check (
        created_by = (select auth.uid())
        and private.is_circle_owner(circle_id)
    );

drop policy if exists circle_invites_delete on public.circle_invites;
create policy circle_invites_delete on public.circle_invites
    for delete to authenticated
    using (private.is_circle_owner(circle_id));

drop policy if exists records_select on public.records;
create policy records_select on public.records
    for select to authenticated
    using (private.is_circle_member(circle_id));

drop policy if exists records_insert on public.records;
create policy records_insert on public.records
    for insert to authenticated
    with check (private.is_circle_member(circle_id));

drop policy if exists records_update on public.records;
create policy records_update on public.records
    for update to authenticated
    using (private.is_circle_member(circle_id))
    with check (private.is_circle_member(circle_id));

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

create or replace function public.create_circle_invite(
    target_circle uuid,
    target_person uuid,
    invite_code   text,
    valid_for     interval default interval '7 days'
)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
    expiry timestamptz;
begin
    if not private.is_circle_owner(target_circle) then
        raise exception 'only the circle owner may create invitations'
            using errcode = '42501';
    end if;

    expiry := now() + valid_for;

    if exists (
        select 1 from public.circle_members
        where circle_id = target_circle and person_id = target_person
    ) then
        raise exception 'that member already has a sync account' using errcode = '23505';
    end if;

    insert into public.circle_invites (code_hash, circle_id, person_id, created_by, expires_at)
    values (
        encode(extensions.digest(invite_code, 'sha256'), 'hex'),
        target_circle,
        target_person,
        auth.uid(),
        expiry
    );

    return expiry;
end;
$$;

revoke all on function public.create_circle_invite(uuid, uuid, text, interval) from public;
grant execute on function public.create_circle_invite(uuid, uuid, text, interval) to authenticated;

-- Existing projects briefly shipped these helpers in `public`; a clean 3.0
-- install creates only the private versions in 0001. Keep this migration valid
-- for both histories.
drop function if exists public.can_access_circle_storage(uuid);
drop function if exists public.is_circle_owner(uuid);
drop function if exists public.is_circle_member(uuid);
