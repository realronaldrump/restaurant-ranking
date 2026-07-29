-- Project creation can configure broad default grants for future objects in
-- `public`. RLS does not protect TRUNCATE, and table-level REFERENCES, TRIGGER,
-- or MAINTAIN privileges are not needed by the mobile client. Keep future
-- migrations fail-closed even if they forget an explicit REVOKE.

alter default privileges for role postgres in schema public
    revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
    revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
    revoke execute on functions from anon, authenticated;

-- Defense in depth for objects that existed before these defaults changed.
revoke truncate, references, trigger on all tables in schema public
    from anon, authenticated;
do $$
begin
    -- MAINTAIN was added in PostgreSQL 17. Supabase projects on earlier major
    -- versions should still be able to apply the hardening chain.
    if current_setting('server_version_num')::integer >= 170000 then
        execute 'revoke maintain on all tables in schema public from anon, authenticated';
    end if;
end;
$$;
revoke all on all sequences in schema public from anon, authenticated;
