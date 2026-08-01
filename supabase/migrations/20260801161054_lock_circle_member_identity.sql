-- A circle membership is the durable binding between an authenticated account
-- and the encrypted person record that owns that account's ratings/reactions.
-- Released clients attempted to "repair" this binding from whichever local
-- person happened to be selected after a merge. Once the previous holder left,
-- that could silently reassign one account to another person's profile.
--
-- Keep the RPC backward compatible for an already-correct no-op, but make an
-- identity change impossible. A real identity change must happen by leaving
-- and redeeming a new invitation, where the account/person binding is created
-- transactionally.
create or replace function public.set_circle_member_person(
    target_circle uuid,
    target_person uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    existing_person uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    select person_id into existing_person
    from public.circle_members
    where circle_id = target_circle
      and user_id = auth.uid();

    if not found then
        raise exception 'circle membership not found' using errcode = '42501';
    end if;

    if existing_person <> target_person then
        raise exception 'a circle membership cannot be reassigned to another member profile'
            using errcode = '22023';
    end if;
end;
$$;

revoke all on function public.set_circle_member_person(uuid, uuid)
    from public, anon, authenticated;
grant execute on function public.set_circle_member_person(uuid, uuid)
    to authenticated;
