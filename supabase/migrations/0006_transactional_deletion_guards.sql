-- Close two narrow service-boundary races found during the 3.0 release audit.

create or replace function public.create_circle(
    target_circle uuid,
    encrypted_name text,
    target_person uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    existing_owner uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    insert into public.circles (id, owner_id, name_cipher)
    values (target_circle, auth.uid(), encrypted_name)
    on conflict (id) do update
        set name_cipher = excluded.name_cipher
        where public.circles.owner_id = auth.uid()
    returning owner_id into existing_owner;

    if not found or existing_owner <> auth.uid() then
        raise exception 'circle identifier is already in use' using errcode = '23505';
    end if;

    insert into public.circle_members (circle_id, user_id, person_id, role)
    values (target_circle, auth.uid(), target_person, 'owner')
    on conflict (circle_id, user_id) do update
        set person_id = excluded.person_id,
            role = 'owner'
        where public.circle_members.user_id = auth.uid();

    return target_circle;
end;
$$;

revoke all on function public.create_circle(uuid, text, uuid) from public;
grant execute on function public.create_circle(uuid, text, uuid) to authenticated;

create or replace function public.finish_circle_deletion(target_circle uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (
        select 1
        from storage.objects
        where bucket_id = 'circle-photos'
          and split_part(name, '/', 1) = target_circle::text
    ) then
        raise exception 'delete the circle photo objects before finishing deletion'
            using errcode = '23503';
    end if;

    delete from public.circles
    where id = target_circle
      and owner_id = auth.uid()
      and deleting_at is not null;
    if not found then
        raise exception 'circle deletion was not started by its owner'
            using errcode = '42501';
    end if;
end;
$$;

revoke all on function public.finish_circle_deletion(uuid) from public;
grant execute on function public.finish_circle_deletion(uuid) to authenticated;
