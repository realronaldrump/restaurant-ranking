-- Do not reveal whether another circle has photo objects to an authenticated
-- caller. Authorization must succeed before the SECURITY DEFINER function
-- inspects Storage. `begin_circle_deletion` also stops new record/photo writes
-- by setting `deleting_at`, so the object check remains race-safe.

create or replace function public.finish_circle_deletion(target_circle uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
    if not exists (
        select 1
        from public.circles
        where id = target_circle
          and owner_id = auth.uid()
          and deleting_at is not null
    ) then
        raise exception 'circle deletion was not started by its owner'
            using errcode = '42501';
    end if;

    if exists (
        select 1
        from storage.objects
        where bucket_id = 'circle-photos'
          -- Apple UUID strings are uppercase while PostgreSQL renders UUIDs
          -- lowercase. Compare UUID values so case cannot bypass the guard.
          and split_part(name, '/', 1)::uuid = target_circle
    ) then
        raise exception 'delete the circle photo objects before finishing deletion'
            using errcode = '23503';
    end if;

    delete from public.circles
    where id = target_circle
      and owner_id = auth.uid()
      and deleting_at is not null;

    -- Preserve the authorization result if a future trigger or concurrent
    -- owner action changes the row between the guard and delete.
    if not found then
        raise exception 'circle deletion was not started by its owner'
            using errcode = '42501';
    end if;
end;
$$;

revoke all on function public.finish_circle_deletion(uuid)
    from public, anon, authenticated;
grant execute on function public.finish_circle_deletion(uuid)
    to authenticated;
