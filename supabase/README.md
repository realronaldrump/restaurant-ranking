# Sync service setup

One-time setup for the Postgres project that Big Beautiful Restaurant Log syncs
against. Design rationale lives in [`docs/MIGRATION_PLAN.md`](../docs/MIGRATION_PLAN.md).

## 1. Create the project

Create a Supabase project and note two values from **Project Settings → API**:

- **Project URL** — `https://<ref>.supabase.co`
- **anon public key**

Neither is a secret. The anon key is a client identifier; every row it can reach
is gated by row level security, and the payloads behind that gate are encrypted
with a per-circle key this project never holds.

## 2. Apply the migrations

Apply every file in `supabase/migrations/` in numerical order. At the time of
the 3.1 release that is:

```
supabase/migrations/0001_circles_and_records.sql
supabase/migrations/0002_photo_storage.sql
supabase/migrations/0003_security_hardening.sql
supabase/migrations/0004_private_rls_helpers.sql
supabase/migrations/0005_secure_default_privileges.sql
supabase/migrations/0006_transactional_deletion_guards.sql
supabase/migrations/0007_membership_presence.sql
supabase/migrations/0008_deletion_authorization_order.sql
supabase/migrations/0009_verified_membership_lifecycle.sql
supabase/migrations/0010_join_codes.sql
supabase/migrations/20260731180047_disambiguate_redeem_join_code_conflict.sql
```

With the CLI:

```sh
supabase link --project-ref <ref>
supabase db push
```

Create future schema objects only through these migrations. Dashboard-created
objects can be owned by Supabase's platform administrator role and inherit
platform-managed grants that an application migration is not permitted to
change. Migration 0005 makes every object created by the app's migration role
fail closed by default.

**Production migration-history note (July 31, 2026).** The linked production
project has the complete schema and the corrected join-code function, but its
`supabase_migrations.schema_migrations` ledger contains the earlier
timestamped/dashboard migration names rather than the repository filenames
`0009`, `0010`, and `20260731180047`. Do not run `supabase db push` against that
project until the history is reconciled with a controlled migration repair or a
new baseline; otherwise the CLI may try to replay objects that already exist.
This bookkeeping issue does not affect the current app while the verified
production schema remains in place.

## 3. Enable Sign in with Apple

The app uses Apple's native Authentication Services flow, not browser OAuth.

1. In the Apple Developer portal, enable **Sign in with Apple** for App ID
   `com.davis.bigbeautifulranking`.
2. In **Supabase → Authentication → Providers → Apple**, enable the provider and
   add `com.davis.bigbeautifulranking` under **Client IDs**.

Native Sign in with Apple sends an identity token straight to the token
endpoint, so no redirect URL, Services ID, OAuth secret, Key ID, or `.p8` key is
required. Those credentials are required only if a web/OAuth Apple flow is
added later. See Supabase's current
[native Swift configuration](https://supabase.com/docs/guides/auth/social-login/auth-apple#configuration-swift-native).

## 4. Point the app at it

Create `Config/Supabase.local.xcconfig` (untracked, `#include?`-ed by
`Config/Supabase.xcconfig`):

```
SUPABASE_HOST = <ref>.supabase.co
SUPABASE_ANON_KEY = <anon key>
```

The host is stored without its scheme because xcconfig treats `//` as the start
of a comment; Info.plist rebuilds the URL as `https://$(SUPABASE_HOST)`.

Leaving the placeholders in place builds an app with syncing off. CI and clean
simulator checkouts intentionally use that local-only configuration.

## 5. Confirm the security boundary

Worth doing deliberately once, with two accounts — the policies *are* the
boundary:

```sql
-- As a member of the circle: rows come back.
select kind, count(*) from records where circle_id = '<circle>' group by kind;

-- As an account that is not a member: must return zero rows, not an error.
select count(*) from records where circle_id = '<circle>';

-- Payloads must be unreadable.
select payload from records limit 1;
```

## 6. Optional keepalive

Supabase plan limits and inactivity behavior can change. Check the project's
current billing page. If the selected plan can pause inactive projects,
`.github/workflows/supabase-keepalive.yml` can send one authenticated request a
day. Add two repository secrets so it can run:

- `SUPABASE_URL` — `https://<ref>.supabase.co`
- `SUPABASE_ANON_KEY`

The request is read-only and RLS-protected. Do not enable the workflow merely to
work around a plan whose current terms do not require it.

## Operating notes

**Where to look when something is wrong.** The SQL editor is the point of the
whole exercise:

```sql
-- Recent activity, newest first.
select kind, id, deleted, device_id, updated_at
from records
where circle_id = '<circle>'
order by updated_ms desc
limit 50;

-- Who is in a circle.
select m.user_id, m.role, m.joined_at, m.last_seen_at, m.app_version
from circle_members m where m.circle_id = '<circle>';

-- Outstanding invitations.
select code_hash, expires_at, redeemed_at from circle_invites
where circle_id = '<circle>';
```

**Invitations.** A join code is twelve Crockford base32 characters, single use,
expiring in seven days. The service stores the code's SHA-256 hash next to a key
envelope: the circle key sealed with AES-GCM under a key derived from the code
itself (PBKDF2-HMAC-SHA256, 200k iterations, per-invitation salt, bound to the
circle id). So the service can match a redemption without being able to open the
envelope, and a database disclosure does not hand anybody a circle. Redemption
inserts the membership and returns the envelope in one transaction, which is why
an account can never end up as a member of a circle it cannot decrypt. Any
member may invite; the joiner claims their own person record as they accept. To
revoke outstanding codes, call `revoke_join_codes` or delete the rows.

**Security boundary.** The authenticated role receives only the minimum table
privileges needed by the app; the anonymous role receives none. RLS is enabled
on every public table. Membership predicates deliberately use `SECURITY
DEFINER` helpers in the unexposed `private` schema because a policy on
`circle_members` cannot safely query the same RLS-protected table. Do not move
those helpers back to `public` or replace them with a recursive policy.

The circle-deletion RPC authorizes the owner before inspecting Storage and
compares the first object-path segment as a UUID rather than as text. Keep both
properties when editing it: Apple clients emit uppercase UUID path segments,
while PostgreSQL renders UUID text in lowercase. A text comparison can miss
real objects and permit orphaned encrypted photo blobs.

**Losing every device that holds a circle key means losing the ability to read
that circle's uploaded records.** That is what end-to-end encryption costs, and
it is why the in-app backup export remains the real backup. The exported archive
is plain JSON and is not encrypted with the circle key.
