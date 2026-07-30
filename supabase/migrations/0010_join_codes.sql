-- Invitations become a join code anybody in the circle can hand over.
--
-- What changed and why
--
-- 1. The circle key no longer travels inside a link. The inviting device seals
--    the key with a key derived from the code (PBKDF2-SHA256, 200k iterations)
--    and uploads only that envelope. The service stores the code's SHA-256
--    hash, so it can match a redemption without ever being able to open the
--    envelope itself. A link is now just a convenient way to type the code.
--
-- 2. An invitation no longer reserves a specific `person_id`. Deciding who the
--    joiner "is" before they accept produced a whole class of dead ends —
--    already-linked members, stale rosters, and invitations that could not be
--    redeemed. The joiner brings their own person record and claims it as they
--    accept, and can correct it afterwards through `set_circle_member_person`.
--
-- 3. Any member may invite. Every member can already read and write every
--    record in the circle, so requiring the owner bought no protection while
--    making a two-person circle depend on who happened to create it.
--
-- The 3.0.2 functions are left in place so an installed build keeps working
-- until it is replaced.

alter table public.circle_invites
    add column if not exists key_envelope text,
    add column if not exists key_salt     text;

-- Older rows reserved a member slot; new rows do not.
alter table public.circle_invites
    alter column person_id drop not null;

-- A code is single use, so hold the row while it is being redeemed.
create index if not exists circle_invites_expiry_idx
    on public.circle_invites (expires_at);

-- ---------------------------------------------------------------------------
-- Creating an invitation
-- ---------------------------------------------------------------------------

create or replace function public.create_join_code(
    target_circle uuid,
    code_digest   text,
    key_envelope  text,
    key_salt      text,
    valid_for     interval default interval '7 days'
)
returns timestamptz
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    expiry timestamptz;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    if not private.is_circle_member(target_circle) then
        raise exception 'only a member of this circle may invite somebody'
            using errcode = '42501';
    end if;

    if code_digest is null or char_length(code_digest) <> 64 then
        raise exception 'malformed join code' using errcode = '22023';
    end if;

    if key_envelope is null or key_salt is null then
        raise exception 'a join code must carry a key envelope' using errcode = '22023';
    end if;

    expiry := now() + valid_for;

    insert into public.circle_invites (
        code_hash, circle_id, person_id, created_by, expires_at, key_envelope, key_salt
    )
    values (code_digest, target_circle, null, auth.uid(), expiry, key_envelope, key_salt)
    on conflict (code_hash) do nothing;

    if not found then
        raise exception 'that join code already exists' using errcode = '23505';
    end if;

    -- Codes are cheap and single use; do not let dead ones accumulate.
    delete from public.circle_invites
    where circle_id = target_circle
      and redeemed_at is null
      and expires_at <= now();

    return expiry;
end;
$$;

revoke all on function public.create_join_code(uuid, text, text, text, interval)
    from public, anon, authenticated;
grant execute on function public.create_join_code(uuid, text, text, text, interval)
    to authenticated;

-- ---------------------------------------------------------------------------
-- Redeeming an invitation
-- ---------------------------------------------------------------------------

-- Returns the circle and the sealed key envelope in one transaction with the
-- membership insert, so a joiner can never end up as a member of a circle they
-- cannot decrypt, or hold a key for a circle they cannot read.
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
    on conflict (circle_id, user_id) do update
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

-- ---------------------------------------------------------------------------
-- Keeping the roster honest
-- ---------------------------------------------------------------------------

-- Two devices can converge on one person record for the same human after a
-- join, which leaves a membership pointing at a record that no longer exists.
-- The account owning the membership repairs its own row.
create or replace function public.set_circle_member_person(
    target_circle uuid,
    target_person uuid
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

    if exists (
        select 1 from public.circle_members
        where circle_id = target_circle
          and person_id = target_person
          and user_id <> auth.uid()
    ) then
        raise exception 'another account already uses that member profile'
            using errcode = '23505';
    end if;

    update public.circle_members
    set person_id = target_person
    where circle_id = target_circle
      and user_id = auth.uid();

    if not found then
        raise exception 'circle membership not found' using errcode = '42501';
    end if;
end;
$$;

revoke all on function public.set_circle_member_person(uuid, uuid)
    from public, anon, authenticated;
grant execute on function public.set_circle_member_person(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Cancelling
-- ---------------------------------------------------------------------------

create or replace function public.revoke_join_codes(target_circle uuid)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    removed integer;
begin
    if not private.is_circle_member(target_circle) then
        raise exception 'only a member of this circle may cancel its invitations'
            using errcode = '42501';
    end if;

    delete from public.circle_invites
    where circle_id = target_circle
      and redeemed_at is null;
    get diagnostics removed = row_count;
    return removed;
end;
$$;

revoke all on function public.revoke_join_codes(uuid) from public, anon, authenticated;
grant execute on function public.revoke_join_codes(uuid) to authenticated;

-- Members may see that an invitation is outstanding, never its hash or key.
drop policy if exists circle_invites_select on public.circle_invites;
create policy circle_invites_select on public.circle_invites
    for select to authenticated
    using (private.is_circle_member(circle_id));

revoke all on public.circle_invites from anon, authenticated;
grant select (circle_id, created_by, created_at, expires_at, redeemed_at, redeemed_by)
    on public.circle_invites to authenticated;
