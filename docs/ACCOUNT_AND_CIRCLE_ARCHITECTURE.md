# Account, friends, and circles

## Decision

Keep three concepts separate:

1. **Account profile** — one person-level identity attached to Sign in with
   Apple, with a display name, optional photo, and an unguessable friend code.
2. **Friendship** — an accepted relationship between two accounts. Friendship
   does not grant access to any dining log.
3. **Circle membership** — explicit access to one encrypted dining log. A
   friend must still accept a circle invitation before membership is created.

This separation makes the UI predictable: People is the address book; Circles
is the list of private logs; each circle has an owner and a roster. Removing a
friend does not silently remove them from existing circles, and leaving a circle
does not unfriend anyone.

The version 3.0.2 invitation repair should remain a narrow release. It fixes
universal-link routing, activation of the joined circle, switching, leaving,
deleting, and member removal. Profiles and friends require a new service schema,
privacy disclosures, key exchange, and a two-account security test matrix, so
they should ship together in a separately tested release rather than being
mixed into the emergency replacement build.

## Why a normal friend table is not enough

The service never receives a circle's symmetric key. A friend picker cannot
silently add an account to a circle unless the app can deliver that key to a
specific device without making it readable to Supabase.

The correct handoff is a per-device encrypted key envelope:

1. Each installation generates a `Curve25519.KeyAgreement.PrivateKey` and keeps
   the private representation in Keychain with `ThisDeviceOnly` accessibility.
2. The installation uploads only its public key.
3. When an owner invites a friend, the owner's phone creates an ephemeral
   X25519 key pair, derives a wrapping key with HKDF using the circle ID,
   invitation ID, sender ID, and recipient device ID as context, and seals the
   32-byte circle key with AES-GCM.
4. Supabase stores the ephemeral public key and sealed envelope. It never sees
   the wrapping key or circle key.
5. The recipient signs in, downloads invitations addressed to their account,
   derives the same wrapping key with their device private key, opens the
   envelope, stores the circle key, and calls one transactional acceptance RPC.

CryptoKit provides X25519 key agreement and HKDF-derived symmetric keys. The
context binding is required so an envelope copied to another invitation,
circle, account, or device fails authentication:

- <https://developer.apple.com/documentation/cryptokit/curve25519/keyagreement>
- <https://developer.apple.com/documentation/cryptokit/sharedsecret>

The current universal-link invitation stays as a recovery/fallback path. It is
also the bootstrap path when a friend has no registered device key yet.

## Proposed service model

All tables live in migrations, have RLS enabled and forced, revoke default
privileges, and expose mutations through narrowly scoped RPCs. Supabase's RLS
and Storage policies remain the authorization boundary:

- <https://supabase.com/docs/guides/database/postgres/row-level-security>
- <https://supabase.com/docs/guides/storage/security/access-control>

### `account_profiles`

| Column | Notes |
| --- | --- |
| `user_id` | Primary key, references `auth.users`, owner-controlled. |
| `display_name` | 1–60 characters. Visible only to the account, accepted friends, and shared-circle members. |
| `friend_code_hash` | Hash of a random 128-bit code. Never use searchable names or email addresses for discovery. |
| `avatar_revision` | Cache-busting integer; the blob path remains server-generated. |
| `created_at`, `updated_at` | Operational metadata. |

Profile names and photos would be service-readable. That is an intentional
privacy tradeoff for cross-circle identity and must be stated in the in-app and
hosted privacy policy before this feature ships. Dining records and circle
photos remain end-to-end encrypted exactly as they are now.

### `account_devices`

| Column | Notes |
| --- | --- |
| `id` | Random device UUID. |
| `user_id` | Owning account. |
| `agreement_public_key` | Raw X25519 public representation. |
| `created_at`, `last_seen_at`, `revoked_at` | Lets a person revoke an old phone. |

An account may have several active devices. Create one key envelope per active
recipient device. Never overwrite a public key in place; revoke the device and
register a new row so outstanding envelopes cannot be redirected.

### `friendships`

Store one canonical row per unordered account pair, with requester, state
(`pending`, `accepted`, `declined`, `blocked`), and timestamps. Discovery uses
an RPC that accepts the plaintext friend code and returns only the matching
minimal profile. Do not provide a global name/email directory.

RLS permits each participant to see the row. Only the recipient can accept or
decline; either participant can remove; a block prevents new requests and
profile disclosure in both directions.

### `account_circle_invites` and `circle_key_envelopes`

An account invite records circle, invited account, intended local `person_id`,
inviter, expiry, state, and a unique ID. Envelope rows are keyed by invite and
recipient device. The invite row contains no circle key.

One SECURITY DEFINER acceptance RPC must lock the invitation and verify all of
the following before inserting membership:

- caller is the intended recipient;
- invitation is pending and unexpired;
- circle is not being deleted;
- intended `person_id` still belongs to the circle and is not linked elsewhere;
- at least one envelope exists for a currently active caller device;
- caller is not already linked to a different person in the circle.

The RPC then inserts `circle_members` and marks the invite accepted in one
transaction. As today, a repeated request by the same account is idempotent;
removal revokes the old invite.

## Proposed app experience

### Account

Settings gains an Account card with avatar, display name, friend code/QR,
registered devices, Sign Out, and Delete Account. Editing the account profile
does not rename historical person records inside circles unless the user chooses
“Use this name in my circles.”

### People

A People screen has Friends, Requests, and Add by Code. It never implies dining
data access. A friend row shows profile, request state, shared circles, Remove
Friend, and Block.

### Circles

The circle switcher remains the top-level list. Each circle detail shows:

- owner and connected members;
- pending invitations with Cancel/Resend;
- Add Friend and Invite by Link;
- Rename (owner), Leave (member), Delete (owner), and Remove from This iPhone;
- sync state for this device, last activity, app version, and actionable errors.

Selecting Add Friend creates an account invite and encrypted envelopes. The
recipient sees it on launch/foreground and in People; accepting downloads and
activates the circle. Without Push Notifications, the app refreshes pending
invites on foreground and offers pull-to-refresh. Push can remain absent.

## Recovery and lifecycle rules

- Server membership is never treated as complete UI state. A join completes
  only after the key is stored, the circle graph is pulled, the invited person
  exists locally, and that circle/person pair is activated.
- If membership commits but download fails, keep the key and pending local join
  state and show Retry. Do not ask for a new invitation.
- Leaving/removal revokes service access and deletes envelopes, but cannot erase
  an already-downloaded offline copy on another phone.
- Pausing sync retains membership, key, and baseline. Leaving or deleting is the
  only operation that forgets the key.
- A replaced phone registers a new device key. Existing friends do not grant it
  old circle keys automatically; an owner re-envelopes the key or sends the
  fallback universal link.
- Account deletion deletes owned circles and their Storage objects, leaves
  non-owned circles, removes friendships/devices/profile/avatar, and finally
  deletes the Auth user through one recoverable service workflow.

## Verification required before shipping

Use three isolated accounts and at least two devices for one account. Test every
RLS policy as member, friend-only, unrelated account, removed member, and blocked
account. A non-authorized select must return zero rows. Verify envelope replay
against a different invitation/circle/device fails, expired/cancelled/accepted
invites are idempotent or rejected as specified, device revocation blocks new
envelopes, avatar Storage follows profile visibility, and account deletion
leaves no profile, friendship, device, envelope, membership, record, or Storage
orphan.
