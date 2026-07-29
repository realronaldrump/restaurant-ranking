-- Big Beautiful Restaurant Log — sync backend schema.
--
-- Design notes
--
-- 1. The server stores ciphertext. Every domain record travels as an AES-GCM
--    sealed box in `records.payload`, encrypted on device with a per-circle key
--    that is never uploaded. The columns kept in clear text are only what the
--    database itself needs to route and authorize a row: circle_id, kind, id,
--    updated_at, deleted.
--
-- 2. One generic `records` table replaces fourteen mirrored entity tables.
--    Because the server cannot read payloads, per-entity columns would buy
--    nothing, and a single table means one RLS policy, one sync loop, and no
--    migration when the app adds an entity kind.
--
-- 3. `updated_at` is always assigned by the database, never by the client.
--    Device clocks disagree; the sync watermark must not.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- Circles and membership
-- ---------------------------------------------------------------------------

create table if not exists public.circles (
    id          uuid primary key,
    owner_id    uuid not null references auth.users (id) on delete cascade,
    name_cipher text,
    deleting_at timestamptz,
    created_at  timestamptz not null default now()
);

create table if not exists public.circle_members (
    circle_id uuid not null references public.circles (id) on delete cascade,
    user_id   uuid not null references auth.users (id) on delete cascade,
    person_id uuid not null,
    role      text not null default 'member' check (role in ('owner', 'member')),
    joined_at timestamptz not null default now(),
    primary key (circle_id, user_id),
    unique (circle_id, person_id)
);

create index if not exists circle_members_user_idx
    on public.circle_members (user_id);

-- Invite codes are stored as a SHA-256 hash. The plaintext code lives only in
-- the invitation the owner sends, so a database disclosure cannot be replayed
-- to join a circle. The circle's encryption key never reaches this table — it
-- travels inside the invitation payload itself.
create table if not exists public.circle_invites (
    code_hash   text primary key,
    circle_id   uuid not null references public.circles (id) on delete cascade,
    person_id   uuid not null,
    created_by  uuid not null references auth.users (id) on delete cascade,
    created_at  timestamptz not null default now(),
    expires_at  timestamptz not null,
    redeemed_by uuid references auth.users (id) on delete set null,
    redeemed_at timestamptz
);

create index if not exists circle_invites_circle_idx
    on public.circle_invites (circle_id);
create index if not exists circle_invites_created_by_idx
    on public.circle_invites (created_by);
create index if not exists circle_invites_redeemed_by_idx
    on public.circle_invites (redeemed_by);
create index if not exists circles_owner_idx
    on public.circles (owner_id);

-- ---------------------------------------------------------------------------
-- Encrypted record store
-- ---------------------------------------------------------------------------

create table if not exists public.records (
    circle_id  uuid not null references public.circles (id) on delete cascade,
    kind       text not null,
    id         uuid not null,
    payload    text,
    deleted    boolean not null default false,
    updated_at timestamptz not null default now(),
    -- Same instant as updated_at, as epoch milliseconds. The sync watermark is
    -- integer arithmetic on every device: no timestamp parsing, no locale, no
    -- disagreement about how many fractional digits Postgres emitted.
    updated_ms bigint not null default 0,
    device_id  uuid,
    primary key (circle_id, kind, id)
);

-- Match the full keyset order used by the pull loop. Recreating the index also
-- upgrades projects that briefly had the two-column pre-keyset version.
drop index if exists public.records_pull_idx;
create index records_pull_idx
    on public.records (circle_id, updated_ms, kind, id);

-- A live row must carry a payload; a tombstone must not.
alter table public.records drop constraint if exists records_payload_presence;
alter table public.records add constraint records_payload_presence
    check ((deleted and payload is null) or (not deleted and payload is not null));

-- ---------------------------------------------------------------------------
-- Server-assigned timestamps
-- ---------------------------------------------------------------------------

-- clock_timestamp() rather than now(): now() is fixed at transaction start, so
-- two rows written in one transaction would share a watermark value and a
-- client resuming mid-transaction could skip the second one.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
    new.updated_at := clock_timestamp();
    new.updated_ms := (extract(epoch from new.updated_at) * 1000)::bigint;
    return new;
end;
$$;

drop trigger if exists records_touch_updated_at on public.records;
create trigger records_touch_updated_at
    before insert or update on public.records
    for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Membership predicate
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER on purpose: a policy on circle_members that queried
-- circle_members through RLS would recurse. This function reads the table with
-- the owner's rights and is the single source of truth for every policy below.
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

-- Owners retain Storage delete access while a circle is in its recoverable
-- deletion state; ordinary members lose all access as soon as deletion begins.
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

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.circles        enable row level security;
alter table public.circle_members enable row level security;
alter table public.circle_invites enable row level security;
alter table public.records        enable row level security;

alter table public.circles        force row level security;
alter table public.circle_members force row level security;
alter table public.circle_invites force row level security;
alter table public.records        force row level security;

drop policy if exists circles_select on public.circles;
create policy circles_select on public.circles
    for select to authenticated
    using (private.is_circle_member(id) or owner_id = (select auth.uid()));

drop policy if exists circles_insert on public.circles;
create policy circles_insert on public.circles
    for insert to authenticated
    with check (owner_id = (select auth.uid()));

drop policy if exists circles_update on public.circles;
create policy circles_update on public.circles
    for update to authenticated
    using (owner_id = (select auth.uid()))
    with check (owner_id = (select auth.uid()));

drop policy if exists circles_delete on public.circles;
create policy circles_delete on public.circles
    for delete to authenticated
    using (owner_id = (select auth.uid()));

drop policy if exists circle_members_select on public.circle_members;
create policy circle_members_select on public.circle_members
    for select to authenticated
    using (private.is_circle_member(circle_id) or private.is_circle_owner(circle_id));

-- Membership creation is restricted to the transactional functions below.
drop policy if exists circle_members_insert_owner on public.circle_members;

-- A member may remove themselves; an owner may remove anyone but themselves.
drop policy if exists circle_members_delete on public.circle_members;
create policy circle_members_delete on public.circle_members
    for delete to authenticated
    using (
        (user_id = (select auth.uid()) and role = 'member')
        or (private.is_circle_owner(circle_id) and user_id <> (select auth.uid()) and role = 'member')
    );

drop policy if exists circle_invites_select on public.circle_invites;
create policy circle_invites_select on public.circle_invites
    for select to authenticated
    using (private.is_circle_owner(circle_id));

drop policy if exists circle_invites_insert on public.circle_invites;
create policy circle_invites_insert on public.circle_invites
    for insert to authenticated
    with check (created_by = (select auth.uid()) and private.is_circle_owner(circle_id));

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

-- Rows are never hard-deleted by the app; a delete is an update that sets the
-- tombstone. Leaving DELETE unpolicied keeps a client from erasing history a
-- peer has not seen yet.

-- ---------------------------------------------------------------------------
-- Invite redemption
-- ---------------------------------------------------------------------------

-- Creates the server circle and its owner membership in one transaction. A
-- retry by the same owner is idempotent; an ID collision with another account
-- is rejected without exposing that circle.
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

    -- RETURNING produces no row when a simultaneous creator won the UUID with
    -- a different account. Check the result before creating membership so the
    -- whole RPC remains atomic even under that race.
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

create or replace function public.redeem_circle_invite(
    invite_code text,
    expected_circle uuid,
    expected_person uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    invitation public.circle_invites%rowtype;
    hashed     text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    hashed := encode(extensions.digest(invite_code, 'sha256'), 'hex');

    select * into invitation
    from public.circle_invites
    where code_hash = hashed
    for update;

    if not found then
        raise exception 'invitation does not exist' using errcode = '22023';
    end if;

    if invitation.circle_id <> expected_circle or invitation.person_id <> expected_person then
        raise exception 'invitation does not match this handoff' using errcode = '22023';
    end if;

    if invitation.redeemed_at is not null then
        -- A response can be lost after the transaction commits, so the same
        -- account may retry. Treat that as success only while its membership
        -- still exists; removal by the owner must revoke the old link.
        if invitation.redeemed_by = auth.uid() and exists (
            select 1 from public.circle_members
            where circle_id = invitation.circle_id
              and user_id = auth.uid()
              and person_id = invitation.person_id
        ) then
            return invitation.circle_id;
        end if;
        raise exception 'invitation has already been redeemed' using errcode = '22023';
    end if;

    if invitation.expires_at <= now() then
        raise exception 'invitation has expired' using errcode = '22023';
    end if;

    if exists (
        select 1 from public.circle_members
        where circle_id = invitation.circle_id
          and user_id = auth.uid()
          and person_id <> invitation.person_id
    ) then
        raise exception 'this account is already linked to another member'
            using errcode = '23505';
    end if;

    if exists (
        select 1 from public.circle_members
        where circle_id = invitation.circle_id
          and person_id = invitation.person_id
          and user_id <> auth.uid()
    ) then
        raise exception 'that member is already linked to another account'
            using errcode = '23505';
    end if;

    insert into public.circle_members (circle_id, user_id, person_id, role)
    values (invitation.circle_id, auth.uid(), invitation.person_id, 'member')
    on conflict (circle_id, user_id) do nothing;

    update public.circle_invites
    set redeemed_by = auth.uid(),
        redeemed_at = now()
    where code_hash = hashed;

    return invitation.circle_id;
end;
$$;

revoke all on function public.redeem_circle_invite(text, uuid, uuid) from public;
grant execute on function public.redeem_circle_invite(text, uuid, uuid) to authenticated;

-- Hashing helper so the client never has to agree with the server on an
-- encoding. The owner sends the plaintext code; only its hash is stored.
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

-- ---------------------------------------------------------------------------
-- Recoverable deletion and account erasure
-- ---------------------------------------------------------------------------

create or replace function public.begin_circle_deletion(target_circle uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    update public.circles
    set deleting_at = coalesce(deleting_at, now())
    where id = target_circle and owner_id = auth.uid();
    if not found then
        raise exception 'only the circle owner may delete synced data'
            using errcode = '42501';
    end if;
end;
$$;

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

create or replace function public.delete_sync_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;
    if exists (select 1 from public.circles where owner_id = auth.uid()) then
        raise exception 'delete owned circles and their Storage objects first'
            using errcode = '23503';
    end if;
    delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.begin_circle_deletion(uuid) from public;
revoke all on function public.finish_circle_deletion(uuid) from public;
revoke all on function public.delete_sync_account() from public;
grant execute on function public.begin_circle_deletion(uuid) to authenticated;
grant execute on function public.finish_circle_deletion(uuid) to authenticated;
grant execute on function public.delete_sync_account() to authenticated;

-- ---------------------------------------------------------------------------
-- Table grants (RLS still applies on top of these)
-- ---------------------------------------------------------------------------

-- New Supabase projects may default-grant every table privilege when "expose
-- new tables" is enabled. TRUNCATE bypasses RLS, so always revoke inherited
-- defaults before adding the exact client surface this app needs.
revoke all on public.circles, public.circle_members, public.circle_invites, public.records
    from anon, authenticated;
grant select                         on public.circles        to authenticated;
grant select,                 delete on public.circle_members to authenticated;
grant select                         on public.circle_invites to authenticated;
grant select, insert, update         on public.records        to authenticated;

revoke all on function public.touch_updated_at() from public;
