# App Store submission checklist

## Product identity

- Product: Big Beautiful Restaurant Log
- Bundle identifier: `com.davis.bigbeautifulranking`
- Sync service: Supabase project (host and anon key supplied through `Config/Supabase.local.xcconfig`)
- Version: 2.6.1 (build 10)
- Devices: iPhone only
- Minimum OS: iOS 17.0

## App Privacy answers

> **Changed in this version — re-answer before the next submission.** Earlier
> releases answered **Data Not Collected** because sharing ran entirely through
> the user's own iCloud account. Circle syncing now uses a developer-operated
> service, so the answers below must be reviewed with Apple's current definitions
> rather than carried forward.

The developer cannot read dining records: every payload and photo is encrypted on
device with a key the service never receives. Apple's App Privacy questions are
about what leaves the device and is linked to identity, not about whether it is
readable, so the honest answers are:

- **Identifiers → User ID:** Collected, linked to identity, used for App
  Functionality. Sign in with Apple establishes a user ID so the service can
  authorize which circle a device may reach.
- **Contact Info → Email Address:** Collected, linked to identity, used for App
  Functionality — whatever Apple returns for the account, including a private
  relay address.
- **User Content → Photos, Other User Content:** Collected, linked to identity,
  used for App Functionality. Declare this even though it is stored as
  ciphertext; it is uploaded and associated with an account.
- Tracking: No.

Nothing is used for advertising, marketing, or analytics, and none of it is
shared with third parties beyond the hosting provider acting as a processor.

Also confirm before upload:

- `PrivacyInfo.xcprivacy` still matches these answers. It currently declares no
  collection; it needs updating alongside this section.
- `ITSAppUsesNonExemptEncryption` is currently `false`. The app encrypts user
  content with AES-GCM through Apple's CryptoKit. Apps using only encryption
  provided by the operating system are generally exempt, which is why the value
  is unchanged — confirm this against Apple's current export-compliance guidance
  for this release rather than assuming.

- Tracking: No
- Third-party advertising: No
- Developer advertising or marketing: No
- Analytics: No
- Data brokers: No
- Third-party SDKs: ZIPFoundation, used only to read user-selected Beli ZIP exports. It contains no advertising, analytics, tracking, accounts, or network service. The sync client is hand-written over `URLSession`; no networking or backend SDK is linked.

The bundled `PrivacyInfo.xcprivacy` declares no collection or tracking and declares `CA92.1` for app-scoped `UserDefaults`, which stores only device-local circle identity, selected circle, onboarding completion, and haptic preference.

## Required App Store Connect fields

- Privacy Policy URL: `https://realronaldrump.github.io/restaurant-ranking/privacy.html`
- User Privacy Choices URL: `https://realronaldrump.github.io/restaurant-ranking/privacy.html#choices`
- Support URL: `https://realronaldrump.github.io/restaurant-ranking/support.html`
- Marketing URL: `https://realronaldrump.github.io/restaurant-ranking/`
- Support contact: `https://github.com/realronaldrump/restaurant-ranking/issues/new?template=support.yml`
- Category: Food & Drink.
- Content rights: the app contains no licensed third-party media.
- Export compliance: the app uses only Apple-provided encryption; `ITSAppUsesNonExemptEncryption` is `NO`.
- Availability: keep iPad unsupported and disable “Make this app available on Apple silicon Mac” so the iPhone app is not distributed for Mac.
- License agreement: use Apple’s Standard Licensed Application End User License Agreement; do not enter a custom EULA.

## What’s New in Version 2.6.1

- Fixed a launch crash and a repeated iCloud warning that could make the app unusable.
- Restored previously accepted circles after a fresh installation instead of opening an empty log.
- Added a safe sharing-recovery tool that keeps the original log while creating a fresh iCloud invitation.
- Improved first-launch feedback while the app looks for an existing iCloud restaurant log.
- Added the installed app version and release date to Settings.

## What’s New in Version 2.5

- Import your complete Beli data-export ZIP with guided Apple Maps matching, original visit dates, ranking order, favorite dishes, captions, and photos.
- Review ambiguous restaurant matches before importing, safely retry an import without creating duplicates, and delete an import later from Settings while preserving pre-existing dining records.
- Keep restaurants with missing Beli visit dates in a dedicated “Date unknown” history section, and mark dates as unknown when logging or editing future outings.
- Combine duplicate shared logs into one outing while preserving every diner’s independent reaction, dishes, memory, and photos.
- Add your own entry to a shared outing, copy only dishes you actually tried, or say that you were not there or do not want to add an entry.
- See who contributed each photo and memory, and keep editing permissions safely scoped to the appropriate diner or outing creator.
- Choose System, Light, or Dark appearance from Settings.
- Preserve shared-outing participation, Beli import history, unknown dates, photo captions, and import undo information in full backups.
- Enjoy clearer outing language, improved history filters, safer duplicate reconciliation, and expanded reliability coverage throughout the app.

## Capabilities to configure in the Apple Developer portal

1. Create or select App ID `com.davis.bigbeautifulranking`.
2. Enable **Sign in with Apple**. iCloud, CloudKit, and Push Notifications are no
   longer used and can be removed from the App ID.
3. Create a Sign in with Apple key (`.p8`) and note the Key ID and Team ID for
   the sync service's Apple auth provider.
4. Set the Xcode project's Development Team.
5. Apply both files in `supabase/migrations/` to the project, following
   `supabase/README.md`.
6. Test an invitation between two physical devices signed into different Apple
   Accounts: create, send, join, edit on both, delete on one, and confirm photos
   arrive on the second device.

There is no longer a schema to promote between environments. Adding an entity
means adding a `SyncKind` case; the `records` table is unchanged, so no
migration accompanies it.

### Retired: CloudKit production schema record

Version 2.6 and earlier mirrored Core Data into CloudKit and required schema
promotion in CloudKit Console before every release that changed
`ManagedObjectModel`. That step no longer exists. The historical deployment
record is in this file's git history.

## Permission behavior

- Location: When In Use only. There is no Always authorization or background visit detection in 1.0.
- Photos: the primary Backfill path uses PhotosPicker without library permission. The optional date-range scan requests read access.
- Notifications: no user-visible notifications are requested.

## Review notes

Signing in is required only to share a log with another person; everything else works without an account. A reviewer can choose “Preview with a sample Salt Lake log” during the Grand Opening to inspect every primary screen without signing in or entering personal data.
