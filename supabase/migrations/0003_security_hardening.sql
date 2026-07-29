-- Tighten grants inherited from Supabase's optional "expose new tables"
-- setting and resolve the database advisor findings discovered during the
-- first production deployment of version 3.0.

revoke all on public.circles, public.circle_members, public.circle_invites, public.records
    from anon, authenticated;
grant select                         on public.circles         to authenticated;
grant select,                 delete on public.circle_members to authenticated;
grant select                         on public.circle_invites  to authenticated;
grant select, insert, update         on public.records         to authenticated;

alter function public.touch_updated_at() set search_path = pg_catalog;
revoke all on function public.touch_updated_at() from public;

-- Supabase creates this event-trigger helper when automatic RLS is selected.
-- It is useful internally but must not be exposed as a PostgREST RPC.
do $$
begin
    if to_regprocedure('public.rls_auto_enable()') is not null then
        execute 'revoke all on function public.rls_auto_enable() from public';
    end if;
end;
$$;

create index if not exists circle_invites_created_by_idx
    on public.circle_invites (created_by);
create index if not exists circle_invites_redeemed_by_idx
    on public.circle_invites (redeemed_by);
create index if not exists circles_owner_idx
    on public.circles (owner_id);

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

drop policy if exists circle_invites_insert on public.circle_invites;
create policy circle_invites_insert on public.circle_invites
    for insert to authenticated
    with check (
        created_by = (select auth.uid())
        and private.is_circle_owner(circle_id)
    );
