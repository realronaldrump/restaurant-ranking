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

-- ---------------------------------------------------------------------------
-- Circles and membership
-- ---------------------------------------------------------------------------

create table if not exists public.circles (
    id          uuid primary key,
    owner_id    uuid not null references auth.users (id) on delete cascade,
    name_cipher text,
    created_at  timestamptz not null default now()
);

create table if not exists public.circle_members (
    circle_id uuid not null references public.circles (id) on delete cascade,
    user_id   uuid not null references auth.users (id) on delete cascade,
    role      text not null default 'member' check (role in ('owner', 'member')),
    joined_at timestamptz not null default now(),
    primary key (circle_id, user_id)
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
    created_by  uuid not null references auth.users (id) on delete cascade,
    created_at  timestamptz not null default now(),
    expires_at  timestamptz not null,
    redeemed_by uuid references auth.users (id) on delete set null,
    redeemed_at timestamptz
);

create index if not exists circle_invites_circle_idx
    on public.circle_invites (circle_id);

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

-- The pull query is always "everything in this circle changed since <watermark>".
create index if not exists records_pull_idx
    on public.records (circle_id, updated_ms);

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
create or replace function public.is_circle_member(target uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select exists (
        select 1
        from public.circle_members m
        where m.circle_id = target
          and m.user_id = auth.uid()
    );
$$;

create or replace function public.is_circle_owner(target uuid)
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

revoke all on function public.is_circle_member(uuid) from public;
revoke all on function public.is_circle_owner(uuid) from public;
grant execute on function public.is_circle_member(uuid) to authenticated;
grant execute on function public.is_circle_owner(uuid) to authenticated;

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
    using (public.is_circle_member(id) or owner_id = auth.uid());

drop policy if exists circles_insert on public.circles;
create policy circles_insert on public.circles
    for insert to authenticated
    with check (owner_id = auth.uid());

drop policy if exists circles_update on public.circles;
create policy circles_update on public.circles
    for update to authenticated
    using (owner_id = auth.uid())
    with check (owner_id = auth.uid());

drop policy if exists circles_delete on public.circles;
create policy circles_delete on public.circles
    for delete to authenticated
    using (owner_id = auth.uid());

drop policy if exists circle_members_select on public.circle_members;
create policy circle_members_select on public.circle_members
    for select to authenticated
    using (public.is_circle_member(circle_id));

-- The owner's own membership row is created alongside the circle. Everyone
-- else arrives through redeem_circle_invite, which runs as SECURITY DEFINER.
drop policy if exists circle_members_insert_owner on public.circle_members;
create policy circle_members_insert_owner on public.circle_members
    for insert to authenticated
    with check (user_id = auth.uid() and public.is_circle_owner(circle_id));

-- A member may remove themselves; an owner may remove anyone but themselves.
drop policy if exists circle_members_delete on public.circle_members;
create policy circle_members_delete on public.circle_members
    for delete to authenticated
    using (
        user_id = auth.uid()
        or (public.is_circle_owner(circle_id) and user_id <> auth.uid())
    );

drop policy if exists circle_invites_select on public.circle_invites;
create policy circle_invites_select on public.circle_invites
    for select to authenticated
    using (public.is_circle_owner(circle_id));

drop policy if exists circle_invites_insert on public.circle_invites;
create policy circle_invites_insert on public.circle_invites
    for insert to authenticated
    with check (created_by = auth.uid() and public.is_circle_owner(circle_id));

drop policy if exists circle_invites_delete on public.circle_invites;
create policy circle_invites_delete on public.circle_invites
    for delete to authenticated
    using (public.is_circle_owner(circle_id));

drop policy if exists records_select on public.records;
create policy records_select on public.records
    for select to authenticated
    using (public.is_circle_member(circle_id));

drop policy if exists records_insert on public.records;
create policy records_insert on public.records
    for insert to authenticated
    with check (public.is_circle_member(circle_id));

drop policy if exists records_update on public.records;
create policy records_update on public.records
    for update to authenticated
    using (public.is_circle_member(circle_id))
    with check (public.is_circle_member(circle_id));

-- Rows are never hard-deleted by the app; a delete is an update that sets the
-- tombstone. Leaving DELETE unpolicied keeps a client from erasing history a
-- peer has not seen yet.

-- ---------------------------------------------------------------------------
-- Invite redemption
-- ---------------------------------------------------------------------------

create or replace function public.redeem_circle_invite(invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    target_circle uuid;
    hashed        text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '28000';
    end if;

    hashed := encode(extensions.digest(invite_code, 'sha256'), 'hex');

    select circle_id into target_circle
    from public.circle_invites
    where code_hash = hashed
      and redeemed_at is null
      and expires_at > now()
    for update;

    if target_circle is null then
        raise exception 'invitation is invalid, expired, or already used'
            using errcode = '22023';
    end if;

    insert into public.circle_members (circle_id, user_id, role)
    values (target_circle, auth.uid(), 'member')
    on conflict (circle_id, user_id) do nothing;

    update public.circle_invites
    set redeemed_by = auth.uid(),
        redeemed_at = now()
    where code_hash = hashed;

    return target_circle;
end;
$$;

revoke all on function public.redeem_circle_invite(text) from public;
grant execute on function public.redeem_circle_invite(text) to authenticated;

-- Hashing helper so the client never has to agree with the server on an
-- encoding. The owner sends the plaintext code; only its hash is stored.
create or replace function public.create_circle_invite(
    target_circle uuid,
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
    if not public.is_circle_owner(target_circle) then
        raise exception 'only the circle owner may create invitations'
            using errcode = '42501';
    end if;

    expiry := now() + valid_for;

    insert into public.circle_invites (code_hash, circle_id, created_by, expires_at)
    values (
        encode(extensions.digest(invite_code, 'sha256'), 'hex'),
        target_circle,
        auth.uid(),
        expiry
    );

    return expiry;
end;
$$;

revoke all on function public.create_circle_invite(uuid, text, interval) from public;
grant execute on function public.create_circle_invite(uuid, text, interval) to authenticated;

-- ---------------------------------------------------------------------------
-- Table grants (RLS still applies on top of these)
-- ---------------------------------------------------------------------------

grant select, insert, update, delete on public.circles        to authenticated;
grant select, insert,         delete on public.circle_members to authenticated;
grant select, insert,         delete on public.circle_invites to authenticated;
grant select, insert, update         on public.records        to authenticated;
