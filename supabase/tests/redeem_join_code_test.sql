BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = extensions, public, pg_catalog;

SELECT plan(4);

INSERT INTO auth.users (id, email)
VALUES
    ('10000000-0000-0000-0000-000000000001', 'circle-owner@example.test'),
    ('10000000-0000-0000-0000-000000000002', 'circle-joiner@example.test');

INSERT INTO public.circles (id, owner_id, name_cipher)
VALUES (
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    'sealed-circle-name'
);

INSERT INTO public.circle_members (circle_id, user_id, person_id, role)
VALUES (
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    'owner'
);

INSERT INTO public.circle_invites (
    code_hash, circle_id, created_by, expires_at, key_envelope, key_salt
)
VALUES (
    repeat('a', 64),
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    now() + interval '1 day',
    'sealed-circle-key',
    'key-salt'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
    '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';

SELECT results_eq(
    $$
        SELECT * FROM public.redeem_join_code(
            repeat('a', 64),
            '30000000-0000-0000-0000-000000000002'
        )
    $$,
    $$
        VALUES (
            '20000000-0000-0000-0000-000000000001'::uuid,
            'sealed-circle-key'::text,
            'key-salt'::text
        )
    $$,
    'a valid join code returns its circle key envelope'
);

SELECT results_eq(
    $$
        SELECT user_id, person_id, role
        FROM public.circle_members
        WHERE circle_id = '20000000-0000-0000-0000-000000000001'
          AND user_id = '10000000-0000-0000-0000-000000000002'
    $$,
    $$
        VALUES (
            '10000000-0000-0000-0000-000000000002'::uuid,
            '30000000-0000-0000-0000-000000000002'::uuid,
            'member'::text
        )
    $$,
    'redeeming inserts the joiner membership'
);

-- The app deliberately cannot read invitation hashes. The authenticated
-- joiner may still inspect the non-secret redemption marker through the member
-- policy, which keeps this assertion in the same caller context as the RPC.

SELECT results_eq(
    $$
        SELECT redeemed_by
        FROM public.circle_invites
        WHERE circle_id = '20000000-0000-0000-0000-000000000001'
          AND created_by = '10000000-0000-0000-0000-000000000001'
    $$,
    $$
        VALUES ('10000000-0000-0000-0000-000000000002'::uuid)
    $$,
    'redeeming marks the invitation as used by the joiner'
);

SET LOCAL ROLE authenticated;

SELECT results_eq(
    $$
        SELECT * FROM public.redeem_join_code(
            repeat('a', 64),
            '30000000-0000-0000-0000-000000000002'
        )
    $$,
    $$
        VALUES (
            '20000000-0000-0000-0000-000000000001'::uuid,
            'sealed-circle-key'::text,
            'key-salt'::text
        )
    $$,
    'the same account can safely retry after a lost response'
);

SELECT * FROM finish();
ROLLBACK;
