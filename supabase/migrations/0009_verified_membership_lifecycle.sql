-- Make circle membership actions explicit and verifiable. A DELETE issued
-- directly through PostgREST can legally affect zero rows under RLS and still
-- return success, which made a missing permission or stale roster look like a
-- completed leave/removal in the app.

create or replace function public.remove_circle_member(
    target_circle uuid,
    target_user uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    if not private.is_circle_owner(target_circle) then
        raise exception 'only the circle owner may remove members'
            using errcode = '42501';
    end if;

    if target_user = auth.uid() then
        raise exception 'the owner cannot remove themselves; delete the circle instead'
            using errcode = '22023';
    end if;

    delete from public.circle_members
    where circle_id = target_circle
      and user_id = target_user
      and role = 'member';

    if not found then
        raise exception 'circle member not found' using errcode = '22023';
    end if;
end;
$$;

create or replace function public.leave_circle(target_circle uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    delete from public.circle_members
    where circle_id = target_circle
      and user_id = auth.uid()
      and role = 'member';

    if not found then
        if exists (
            select 1 from public.circles
            where id = target_circle and owner_id = auth.uid()
        ) then
            raise exception 'the owner cannot leave; delete the circle instead'
                using errcode = '22023';
        end if;
        raise exception 'circle membership not found' using errcode = '22023';
    end if;
end;
$$;

revoke all on function public.remove_circle_member(uuid, uuid)
    from public, anon, authenticated;
grant execute on function public.remove_circle_member(uuid, uuid)
    to authenticated;

revoke all on function public.leave_circle(uuid)
    from public, anon, authenticated;
grant execute on function public.leave_circle(uuid)
    to authenticated;
