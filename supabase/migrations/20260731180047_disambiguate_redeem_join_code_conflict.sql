-- `circle_id` is both an output parameter of this table-returning function and
-- a column in circle_members. In PL/pgSQL, naming the conflict target columns
-- directly therefore raises "column reference circle_id is ambiguous" before
-- a join code can be redeemed. Target the existing primary-key constraint by
-- name so PostgreSQL never has to resolve that identifier.
create or replace function public.redeem_join_code(
    code_digest   text,
    target_person uuid
)
returns table (circle_id uuid, key_envelope text, key_salt text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    invitation public.circle_invites%rowtype;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    select * into invitation
    from public.circle_invites
    where code_hash = code_digest
    for update;

    if not found then
        raise exception 'that join code is not valid' using errcode = '22023';
    end if;

    if invitation.key_envelope is null then
        raise exception 'that invitation was made by an older version of the app'
            using errcode = '22023';
    end if;

    if exists (
        select 1 from public.circles
        where id = invitation.circle_id and deleting_at is not null
    ) then
        raise exception 'that circle is being deleted' using errcode = '22023';
    end if;

    -- A response can be lost after the transaction commits, so the same
    -- account may retry. That is success while its membership still exists;
    -- removal by the owner must revoke the old code.
    if invitation.redeemed_at is not null then
        if invitation.redeemed_by = auth.uid() and exists (
            select 1 from public.circle_members
            where public.circle_members.circle_id = invitation.circle_id
              and user_id = auth.uid()
        ) then
            return query
                select invitation.circle_id, invitation.key_envelope, invitation.key_salt;
            return;
        end if;
        raise exception 'that join code has already been used' using errcode = '22023';
    end if;

    if invitation.expires_at <= now() then
        raise exception 'that join code has expired' using errcode = '22023';
    end if;

    insert into public.circle_members (circle_id, user_id, person_id, role)
    values (invitation.circle_id, auth.uid(), target_person, 'member')
    on conflict on constraint circle_members_pkey do update
        set person_id = excluded.person_id
        where public.circle_members.user_id = auth.uid();

    update public.circle_invites
    set redeemed_by = auth.uid(),
        redeemed_at = now()
    where code_hash = code_digest;

    return query
        select invitation.circle_id, invitation.key_envelope, invitation.key_salt;
end;
$$;

revoke all on function public.redeem_join_code(text, uuid)
    from public, anon, authenticated;
grant execute on function public.redeem_join_code(text, uuid) to authenticated;
