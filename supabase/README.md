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

In order, from the SQL editor or the CLI:

```
supabase/migrations/0001_circles_and_records.sql
supabase/migrations/0002_photo_storage.sql
```

With the CLI:

```sh
supabase link --project-ref <ref>
supabase db push
```

## 3. Enable Sign in with Apple

**Authentication → Providers → Apple.** You need, from the Apple Developer
portal:

- Services ID (or the app's bundle ID, `com.davis.bigbeautifulranking`, for
  native sign-in)
- Team ID
- Key ID and the `.p8` signing key

Native Sign in with Apple sends an identity token straight to the token
endpoint, so no redirect URL is involved. Add `com.davis.bigbeautifulranking` to
the provider's authorized client IDs.

## 4. Point the app at it

Create `Config/Supabase.local.xcconfig` (untracked, `#include?`-ed by
`Config/Supabase.xcconfig`):

```
SUPABASE_HOST = <ref>.supabase.co
SUPABASE_ANON_KEY = <anon key>
```

The host is stored without its scheme because xcconfig treats `//` as the start
of a comment; Info.plist rebuilds the URL as `https://$(SUPABASE_HOST)`.

Leaving the placeholders in place builds a device-only app with syncing off,
which is how the simulator and the test suite run.

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

## 6. Keep the project awake

Free projects pause after seven days without a request.
`.github/workflows/supabase-keepalive.yml` sends one request a day. Add two
repository secrets so it can run:

- `SUPABASE_URL` — `https://<ref>.supabase.co`
- `SUPABASE_ANON_KEY`

A paid project does not pause; the workflow is harmless either way.

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
select m.user_id, m.role, m.joined_at
from circle_members m where m.circle_id = '<circle>';

-- Outstanding invitations.
select code_hash, expires_at, redeemed_at from circle_invites
where circle_id = '<circle>';
```

**Invitations.** Single use, expiring in seven days, stored only as a SHA-256
hash. The plaintext code and the circle key exist only inside the invitation
link, so it must be delivered the way you would deliver a house key — directly,
in a conversation you trust. Anyone who opens the link joins the circle. To
revoke one before it is used, delete its row.

**Losing every device that holds a circle key means losing the ability to read
that circle's uploaded records.** That is what end-to-end encryption costs, and
it is why the in-app backup export remains the real backup. The exported archive
is plain JSON and is not encrypted with the circle key.
