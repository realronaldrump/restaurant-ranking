# Replacing iCloud sharing with an encrypted sync service

Status: implemented and compiled under Swift 6. The unit suite passes, and all
nine migrations have been applied to the production Supabase project. Live RLS
checks with three isolated accounts verified member access, non-member
invisibility, rejected writes, invitation expiry, single redemption, idempotent
retry, and member removal. See [What is left](#what-is-left) for release-device
validation that cannot be simulated faithfully.

## Why the old design failed

The app used `NSPersistentCloudKitContainer` with a private store and a shared
store, and `CKShare` for circle collaboration. Three properties of that stack,
not three bugs, produced the instability:

1. **A CloudKit record can belong to exactly one share, permanently.** When a
   share broke there was no repair. `CloudSharingService.recoveryPayload`
   existed to work around this: it duplicated the entire object graph with fresh
   UUIDs and shared the copy. That is a rebuild, not a fix, and it left the
   original circle behind as clutter every time.
2. **The schema had to bend to CloudKit.** Every non-optional attribute needed a
   model-level default (`ManagedObjectModel.cloudKitDefaultValue`), uniqueness
   constraints were unavailable, and schema changes required manual dev→prod
   promotion in the CloudKit Dashboard. The absence of uniqueness is why
   `AppStore` carries hand-written reconciliation for people, locations, dishes
   and outings created concurrently on two devices.
3. **Nothing was observable.** No server logs, no query console, no way to see
   what a peer's device had actually written. Failures surfaced as opaque
   `CKError` partial failures with no recourse but waiting.

On top of that, meal photos — roughly 0.5–1 MB each at 2048 px, plus a 480 px
thumbnail — were stored as Core Data blobs and mirrored as CKAssets through the
same path as a one-byte rating. The heaviest payload rode the least debuggable
layer.

## What replaces it

Core Data stays exactly where it is, as an ordinary `NSPersistentContainer`, and
remains the source of truth on the device. Sharing becomes a separate,
inspectable delta sync against Postgres.

```
   Core Data (local truth)
        │
        │  SyncSnapshotBuilder — encode the circle as records
        ▼
   [SyncKey: LocalSyncRecord]  ──┐
                                 │  SyncPlanner — pure merge rules
   [SyncKey: DecodedSyncRecord]──┤     (local, remote, baseline)
        ▲                        │
        │                        ▼
   pull │                    SyncPlan
        │                        │
        │        ┌───────────────┴───────────────┐
        │        ▼                               ▼
        │   SyncApplier                    seal + push
        │   (upsert into Core Data)        (AES-GCM per record)
        │                                       │
        └───────────── SupabaseClient ──────────┘
                     (URLSession → PostgREST)
```

### Decisions worth stating plainly

**Postgres, not another opaque sync box.** The single biggest fix for "impossible
to troubleshoot" is a SQL console. Every row, every timestamp, every membership
is visible and queryable.

**End-to-end encryption, so the privacy promise survives.** The product's stated
principle was that the developer operates no server and cannot read dining
records. A hosted database would ordinarily end that. It does not here: every
record payload and every photo blob is sealed with AES-GCM on device using a
per-circle key that is generated locally, stored in the Keychain, and delivered
to other members inside the invitation — never through the server. The service
holds ciphertext.

This is cheap for this app specifically because *no query is ever run server
side*. Every device already pulls the whole circle into memory (`AppStore` holds
all objects and filters locally), so giving up server-side filtering costs
nothing.

**No SDK.** The app talks to PostgREST, GoTrue and Storage with `URLSession`
over a fixed schema — about a dozen requests. That keeps the dependency graph at
one package (ZIPFoundation, for Beli imports), keeps the "no third-party SDK"
privacy claim true, and leaves every request inspectable.

**One generic `records` table, not fourteen mirrored ones.** Since the server
cannot read payloads, per-entity columns buy nothing. One table means one RLS
policy, one sync loop, and no migration when the app adds an entity kind.

**The existing backup format is the wire format.** `AppBackupArchive`'s record
structs — already `Codable`, already UUID-keyed with explicit foreign keys,
already validated and unit tested — are what gets encrypted and sent. No second
serialization layer was written.

**Content hashes, not timestamps, decide what changed.** A record rewritten with
identical values produces no traffic. Fingerprints are computed over plaintext,
because AES-GCM's per-seal nonce means identical values encrypt differently
every time.

## The database

`supabase/migrations/0001_circles_and_records.sql`

| Table | Purpose |
| --- | --- |
| `circles` | Circle identity and owner. `name_cipher` is sealed. |
| `circle_members` | Who may reach a circle's rows. |
| `circle_invites` | SHA-256 hash of an invite code, single use, expiring. |
| `records` | Every domain record as `(circle_id, kind, id) → sealed payload`. |

Clear-text columns are only what the database needs to route and authorize:
`circle_id`, `kind`, `id`, `updated_at`, `updated_ms`, `deleted`. Everything
else is inside `payload`.

Two details that matter more than they look:

- **`updated_ms` is epoch milliseconds, assigned by a trigger.** The sync
  watermark is integer arithmetic on every device — no timestamp parsing, no
  locale, no argument about how many fractional digits Postgres emitted.
- **The trigger uses `clock_timestamp()`, not `now()`.** `now()` is fixed at
  transaction start, so two rows written in one transaction would share a
  watermark and a client resuming mid-transaction could step over the second.

`private.is_circle_member()` is `SECURITY DEFINER` deliberately: a policy on
`circle_members` that queried `circle_members` through RLS would recurse. It is
the single predicate every policy is built from. The `private` schema is not
exposed through the Data API, and migration 0004 grants only the authenticated
role permission to invoke the authorization helpers.

Deletes are not policied on `records`. A removal is an update that sets the
tombstone, so one client cannot erase history a peer has not seen yet.

`supabase/migrations/0002_photo_storage.sql` adds the private `circle-photos`
bucket, keyed `<circle_id>/<photo_id>.full` and `.thumb`, authorized on the
first path segment.

`supabase/migrations/0003_security_hardening.sql` removes broad default table
grants (including `TRUNCATE`, which bypasses RLS), grants only the operations the
app needs, indexes foreign-key and pull paths, and hardens helper search paths.
`supabase/migrations/0004_private_rls_helpers.sql` moves the deliberate
`SECURITY DEFINER` membership helpers out of the exposed `public` schema.
`supabase/migrations/0005_secure_default_privileges.sql` removes broad inherited
privileges from future tables, sequences, and functions so later migrations
remain fail-closed even when the project was created with automatic exposure.
`supabase/migrations/0006_transactional_deletion_guards.sql` makes circle
creation safe under simultaneous UUID collisions and refuses to finalize a
circle deletion while any encrypted photo objects remain in Storage.

## Conflict rules

Implemented in `SyncPlanner`, which is free of Core Data, networking and crypto
so the rules can be tested directly — see `SyncPlannerTests`.

| Local | Remote | Result |
| --- | --- | --- |
| unchanged | unchanged | nothing |
| changed | unchanged | push local |
| unchanged | changed | apply remote |
| changed | changed | **keep local, push it**, count a conflict |
| deleted | unchanged | push tombstone |
| unchanged | deleted | delete locally |
| edited | deleted | **keep local, push it** |
| deleted | edited | **apply remote** |

Concurrent edits keep this device's version. The domain makes that safe: ratings,
dish entries, comparisons and participants are all keyed to a `personID`, so two
diners edit different rows almost by construction. The genuinely shared rows are
restaurant details and dish names, where a stale overwrite costs one re-edit and
never loses a visit. Preferring the local side also means the person looking at
the screen sees their own change survive.

Deletion loses to editing in both directions, for the same reason: restoring a
record someone deleted is recoverable, losing an edit is not.

Two guards keep a pass from quietly going in circles:

- **Republish after apply.** If storing a remote record produces a different
  value than the one that arrived — Core Data setters normalise companion lists
  and tag arrays — the stored version is pushed back. Without that the two sides
  would disagree forever and every pass would re-apply the same record.
- **Replay a request that arrived mid-pass.** A pass reads the local graph once,
  near its start. An edit landing after that read is remembered and the pass runs
  again rather than waiting for some later trigger.

## Photos

Photo metadata syncs as an ordinary record with `fullData` and `thumbnailData`
nulled. `SyncSnapshotBuilder` never touches those properties, so Core Data's
external binary storage never faults the bytes in — a sync pass stays at a few
hundred kilobytes regardless of how many photos the log holds.

Bytes go to Storage separately, sealed with the same circle key, tracked by
`uploadedPhotoIDs` / `downloadedPhotoIDs` in the baseline. Photo failures are
logged and swallowed: a missing image is a degraded photo, not a broken log, and
must not stop ratings and visits from converging.

## Migrating existing data

**Local records are untouched.** The main store keeps its filename
(`BigBeautiful-private.sqlite`), so upgrading is not a restore — the log is
simply there.

**The old shared store is folded in once.** Records that arrived through an
accepted `CKShare` lived in a second store, `BigBeautiful-shared.sqlite`.
`PersistenceController.adoptLegacySharedStoreIfPresent` opens it read-only,
merges every object into the main store by UUID via `LegacyStoreConsolidator`,
then moves the file into `Application Support/RetiredCloudKitStore/` rather than
deleting it. The consolidator is model-driven — it walks
`NSEntityDescription.attributesByName` and the to-one relationships — so a future
entity is carried across without anyone remembering to update it.

If the merge fails, nothing is deleted and the person is told to export a backup
from the previous version.

**Nothing is uploaded until sync is turned on.** The first pass after enabling
sync sees an empty baseline and pushes the whole circle.

## Rollout

1. Create the Supabase project, apply every migration in numerical order, and
   enable Apple as an auth provider. `supabase/README.md` is the runbook.
2. Put the project host and anon key in `Config/Supabase.local.xcconfig`
   (untracked). A build without them runs entirely on device with syncing off —
   which is also how tests and the simulator run.
3. Build on the device that holds the complete history. Confirm the legacy
   shared store was adopted and the log looks right.
4. Turn on syncing for the circle, then create an invitation and open it on the
   second device.
5. Verify in the SQL console: `select kind, count(*) from records where circle_id
   = '…' group by kind;` should match the first device's counts, and `payload`
   should be unreadable base64.

Rollback within the app is not needed. If the service is unreachable the app
keeps working on device, and the previous build can be reinstalled from
TestFlight — its stores are untouched apart from the retired shared store, which
is still on disk.

## Cost and upkeep

Plan limits and inactivity behavior are operational settings rather than part
of the architecture and may change. Check the Supabase billing page for the
current project. An optional read-only, RLS-protected keepalive workflow is
included for plans that pause inactive projects.

## Privacy and App Store consequences

These were the real cost of the change and are done in this branch:

- `PRIVACY.md` and `docs/privacy.html` now describe the sync service, exactly
  what it holds, and what it cannot read.
- `README.md` no longer claims there is no hosted backend.
- Entitlements drop iCloud/CloudKit and add Sign in with Apple.
- `APP_STORE_SUBMISSION.md` records the privacy-label change to make on the next
  submission.

Sign in with Apple is used only to prove which member a device belongs to. The
app requests the email scope, stores nothing from the credential except the
session token, and keeps the refresh token in the Keychain as
`ThisDeviceOnly` — a replacement phone re-joins with an invitation, which is the
same trust step as the original join.

## What the service can still see

Stated plainly, because "encrypted" is not the same as "invisible":

- How many records a circle holds, and of which kinds.
- When they changed, and which device wrote them.
- Which accounts belong to which circle, and the email Apple returns.
- The size of each photo.

It cannot see restaurant names, dates, ratings, dishes, notes, companions,
photos, or any circle's name.

## What is left

- **Enable native Sign in with Apple** for the production App ID and Supabase
  provider. Native-only Swift authentication requires the bundle ID as the
  provider client ID and does not require the web OAuth `.p8` secret.
- **Exercise a two-device sync** end to end on physical devices: invite, join,
  concurrent edits, deletions, removed-member behavior, photo upload/download,
  offline recovery, and account/circle deletion.
- **Validate the legacy migration on a physical device** that contains an
  authentic pre-3.0 shared store and a large photo library. Automated tests cover
  copied-store relationships, blobs, and failure recovery, but cannot reproduce
  device storage pressure or launch timing exactly.
- **Update and publish the App Store privacy answers** before submission, then
  complete Release archive and TestFlight review checks.
