-- Make the member roster useful without exposing dining content. These are
-- deliberately operational fields only: installed app version and the last
-- time that account successfully contacted this circle.

alter table public.circle_members
    add column if not exists last_seen_at timestamptz,
    add column if not exists app_version text;

alter table public.circle_members
    drop constraint if exists circle_members_app_version_length;
alter table public.circle_members
    add constraint circle_members_app_version_length
    check (
        app_version is null
        or (char_length(btrim(app_version)) between 1 and 32)
    );

-- Authenticated clients receive UPDATE only for these two columns. The RLS
-- policy restricts the row to the caller's own membership, and the trigger
-- makes last_seen_at server-authored even if somebody calls PostgREST directly.
grant update (last_seen_at, app_version)
    on public.circle_members to authenticated;

drop policy if exists circle_members_update_presence on public.circle_members;
create policy circle_members_update_presence on public.circle_members
    for update to authenticated
    using (
        user_id = (select auth.uid())
        and private.is_circle_member(circle_id)
    )
    with check (
        user_id = (select auth.uid())
        and private.is_circle_member(circle_id)
    );

create or replace function public.normalize_circle_member_presence()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
    new.last_seen_at := clock_timestamp();
    new.app_version := btrim(new.app_version);
    return new;
end;
$$;

revoke all on function public.normalize_circle_member_presence()
    from public, anon, authenticated;

drop trigger if exists circle_members_normalize_presence
    on public.circle_members;
create trigger circle_members_normalize_presence
    before update of last_seen_at, app_version on public.circle_members
    for each row execute function public.normalize_circle_member_presence();

create or replace function public.touch_circle_membership(
    target_circle uuid,
    client_version text
)
returns timestamptz
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
    touched_at timestamptz;
begin
    if client_version is null
       or char_length(btrim(client_version)) not between 1 and 32 then
        raise exception 'client version must contain 1 to 32 characters'
            using errcode = '22023';
    end if;

    update public.circle_members
       set last_seen_at = clock_timestamp(),
           app_version = btrim(client_version)
     where circle_id = target_circle
       and user_id = (select auth.uid())
    returning last_seen_at into touched_at;

    if not found then
        raise exception 'circle membership not found'
            using errcode = '42501';
    end if;

    return touched_at;
end;
$$;

revoke all on function public.touch_circle_membership(uuid, text)
    from public, anon, authenticated;
grant execute on function public.touch_circle_membership(uuid, text)
    to authenticated;

comment on column public.circle_members.last_seen_at is
    'Server-authored time of the account most recently contacting this circle.';
comment on column public.circle_members.app_version is
    'Non-sensitive client release/build used to diagnose member compatibility.';
