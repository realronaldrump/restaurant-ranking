# App Store submission checklist

## Product identity

- Product: Big Beautiful Restaurant Log
- Bundle identifier: `com.davis.bigbeautifulranking`
- Sync service: Supabase project (host and anon key supplied through `Config/Supabase.local.xcconfig`)
- Version: 3.0 (build 10)
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

- **Contact Info → Name:** Collected, linked to identity, used for App
  Functionality. Circle-member names are part of encrypted synced content.
- **Contact Info → Email Address:** Collected, linked to identity, used for App
  Functionality. Supabase Auth retains the address Apple provides, including a
  private relay address when the person chooses Hide My Email.
- **Identifiers → User ID:** Collected, linked to identity, used for App
  Functionality. Sign in with Apple establishes a user ID so the service can
  authorize which circle a device may reach.
- **Identifiers → Device ID:** Collected, linked to identity, used for App
  Functionality. A random per-installation UUID labels writes for idempotent
  delta sync; it is not an advertising identifier.
- **Location → Precise Location:** Collected, linked to identity, used for App
  Functionality. A meal or restaurant can include coordinates in its encrypted
  synced record when the person grants foreground location access.
- **User Content → Photos, Other User Content:** Collected, linked to identity,
  used for App Functionality. Declare this even though it is stored as
  ciphertext; it is uploaded and associated with an account.
- Tracking: No.

Nothing is used for advertising, marketing, or analytics, and none of it is
shared with third parties beyond the hosting provider acting as a processor.

`PrivacyInfo.xcprivacy` declares Name, Email Address, Photos or Videos, Other
User Content, User ID, Device ID, and Precise Location as linked to identity,
used only for App Functionality, and not used for tracking.

Also confirm before upload:
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

The bundled privacy manifest declares no tracking and declares `CA92.1` for
app-scoped `UserDefaults`, which stores only device-local circle identity,
selected circle, onboarding completion, haptic preference, appearance, and the
sync watermark/baseline. It also declares `DDA9.1` for file timestamps used when
reading user-selected imports and backups.

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

## What’s New in Version 3.0

- Added optional end-to-end encrypted circle syncing so shared dining logs stay current across devices.
- Added Sign in with Apple and single-use invitations for securely joining a dining circle.
- Improved reliability when edits arrive during a sync and when shared records need to be reconciled.
- Kept encrypted photos on a separate transfer path so everyday ratings and visit updates stay lightweight.
- Preserved dining history from previously accepted iCloud circles when upgrading to the new sync system.

## Capabilities to configure in the Apple Developer portal

1. Create or select App ID `com.davis.bigbeautifulranking`.
2. Enable **Sign in with Apple** and **Associated Domains**. The associated
   domain is `applinks:realronaldrump.github.io`.
3. Confirm iCloud, CloudKit, and Push Notifications are absent from the App ID
   and the generated provisioning profile.
4. In Supabase's Apple provider, add `com.davis.bigbeautifulranking` as a client
   ID. This native-only flow does not require a Services ID, OAuth secret, Key
   ID, or `.p8` key.
5. Confirm the Xcode project's Development Team is `CZ3N26YJ75`.
6. Apply every file in `supabase/migrations/` in numerical order, following
   `supabase/README.md`.
7. Verify `https://realronaldrump.github.io/.well-known/apple-app-site-association`
   serves JSON without a redirect and contains the production Team ID and bundle ID.
8. Test an invitation between two physical devices signed into different Apple
   Accounts: create, send, join, edit on both, delete on one, and confirm photos
   arrive on the second device.

There is no longer a schema to promote between environments. Adding an entity
means adding a `SyncKind` case; the `records` table is unchanged, so no
migration accompanies it.

## Permission behavior

- Location: When In Use only. There is no Always authorization or background visit detection in 3.0.
- Photos: the primary Backfill path uses PhotosPicker without library permission. The optional date-range scan requests read access.
- Notifications: no user-visible notifications are requested.

## Review notes

Signing in is required only to share a log with another person; everything else works without an account. A reviewer can choose “Preview with a sample Salt Lake log” during the Grand Opening to inspect every primary screen without signing in or entering personal data.
