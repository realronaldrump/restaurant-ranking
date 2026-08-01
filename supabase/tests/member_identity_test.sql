BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = extensions, public, pg_catalog;

SELECT plan(3);

INSERT INTO auth.users (id, email)
VALUES ('11000000-0000-0000-0000-000000000001', 'identity-owner@example.test');

INSERT INTO public.circles (id, owner_id, name_cipher)
VALUES (
    '21000000-0000-0000-0000-000000000001',
    '11000000-0000-0000-0000-000000000001',
    'sealed-circle-name'
);

INSERT INTO public.circle_members (circle_id, user_id, person_id, role)
VALUES (
    '21000000-0000-0000-0000-000000000001',
    '11000000-0000-0000-0000-000000000001',
    '31000000-0000-0000-0000-000000000001',
    'owner'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" =
    '{"sub":"11000000-0000-0000-0000-000000000001","role":"authenticated"}';

SELECT lives_ok(
    $$
        SELECT public.set_circle_member_person(
            '21000000-0000-0000-0000-000000000001',
            '31000000-0000-0000-0000-000000000001'
        )
    $$,
    'an already-correct membership remains a backward-compatible no-op'
);

SELECT throws_ok(
    $$
        SELECT public.set_circle_member_person(
            '21000000-0000-0000-0000-000000000001',
            '31000000-0000-0000-0000-000000000002'
        )
    $$,
    '22023',
    'a circle membership cannot be reassigned to another member profile',
    'a roster refresh cannot take over another person profile'
);

SELECT results_eq(
    $$
        SELECT person_id
        FROM public.circle_members
        WHERE circle_id = '21000000-0000-0000-0000-000000000001'
          AND user_id = '11000000-0000-0000-0000-000000000001'
    $$,
    $$ VALUES ('31000000-0000-0000-0000-000000000001'::uuid) $$,
    'the original account/person binding remains unchanged'
);

SELECT * FROM finish();
ROLLBACK;
