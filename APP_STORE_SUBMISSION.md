# App Store submission checklist

## Product identity

- Product: Big Beautiful Restaurant Log
- Bundle identifier: `com.davis.bigbeautifulranking`
- Sync service: Supabase project (host and anon key supplied through `Config/Supabase.local.xcconfig`)
- Version: 3.1.3 (build 17)
- Devices: iPhone only
- Minimum OS: iOS 17.0

## App Privacy answers

> **Completed for 3.0.2 on July 29, 2026 and unchanged for 3.1.3.** Earlier
> releases answered **Data Not Collected** because sharing ran entirely through
> the user's own iCloud account. App Store Connect publishes the seven data types
> below as linked to the user, used for App Functionality, and not used for
> tracking. 3.1.3 collects nothing new: it fixes a sync serialization edge case;
> it changes no data categories and does not change what leaves the device.

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
  content with AES-GCM through Apple's CryptoKit and, from 3.1.1, derives an
  invitation's wrapping key with PBKDF2-HMAC-SHA256 through Apple's CommonCrypto.
  Both are operating-system-provided, so the exemption reasoning is unchanged —
  confirm it against Apple's current export-compliance guidance for this release
  rather than assuming.

- Tracking: No
- Third-party advertising: No
- Developer advertising or marketing: No
- Analytics: No
- Data brokers: No
- Third-party SDKs: ZIPFoundation, used only to read user-selected Beli ZIP exports. It contains no advertising, analytics, tracking, accounts, or network service. The sync client is hand-written over `URLSession`; no networking or backend SDK is linked.

The bundled privacy manifest declares no tracking and declares `CA92.1` for
app-scoped `UserDefaults`, which stores only the device's circle and person
identifiers, onboarding completion, haptic preference, appearance, and the sync
watermark/baseline. It also declares `DDA9.1` for file timestamps used when
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
- Availability: all 175 countries or regions on app release. Keep iPad unsupported and disable both “Make this app available on Apple silicon Mac” and Apple Vision Pro distribution so this remains an iPhone-only app.
- License agreement: use Apple’s Standard Licensed Application End User License Agreement; do not enter a custom EULA.

## Final release gates

- App Store build: version 3.1.3, build 17. It supersedes submitted build 3.1.2
  (build 16), whose mixed live-record/tombstone sync batches could be rejected by
  the production payload-presence constraint, and build 13, whose invitation
  links could open the app and then do nothing, and which could crash while a
  circle was being deleted.
- **Apply `supabase/migrations/0010_join_codes.sql` before this build reaches
  anybody.** Join codes cannot be created or redeemed without it. The migration
  is additive and leaves the 3.0.2 functions in place, so build 13 keeps working
  until it is replaced. Applied to the production project on July 30, 2026;
  verified by the six-row check in `supabase/README.md`.
- TestFlight: assign build 17 to the external **Big Beautiful Testers** group,
  complete the two-device soak below, and only then submit the App Store draft.
- EU Digital Services Act: completed by the Account Holder and shown as
  **Active** for all 27 applicable countries or regions on July 29, 2026.
- After the soak passes, open **App Review → Draft Submission** and choose
  **Submit for Review**. The version is configured to release automatically
  after approval.

### Two-device TestFlight soak

Two iPhones on different Apple Accounts. Steps 3 to 6 cover the 3.1.1
invitation/merge fixes and the 3.1.3 mixed-record sync fix, so do not sign off
without them.

1. Install version 3.1.3, build 17 on both phones.
2. On the upgrading phone, confirm the existing restaurants, visits, rankings,
   relationships, and photos survive, and that a log left behind in a second
   circle by an older build has been folded into the one log.
3. On phone A: **More → Share → Create a Join Code**. On phone B, enter the code
   under **Got a join code?**. Confirm B ends up with A's restaurants and
   outings, and that A sees B in the roster.
4. Repeat the join on a fresh install using the *link* rather than the code,
   from a cold start: force-quit the app first, tap the link, and confirm the
   Join Circle sheet appears rather than the app simply opening.
5. Before joining on B, log a distinctive restaurant there. After joining,
   confirm that restaurant appears on A. This is the regression that made a
   shared circle look empty.
6. Create and edit a clearly named temporary visit on each phone, add a photo,
   and confirm both devices converge without duplicates.
7. Make a conflicting edit and deletion of the temporary visit and confirm the
   edited version is preserved.
8. Tag the other member on an outing and confirm the pending-entry prompt
   appears on their home screen and that their entry syncs back.
9. On the owner phone, remove the member. Confirm the member's device stops
   syncing, keeps its local copy, and that their outings remain in the owner's
   log.
10. Re-invite with a new code and confirm the rejoin works.
11. Leave the circle from the member phone. Confirm no crash, that the dining log
    is intact, and that it resumes syncing privately under a new circle.
12. Sign out and back in on both phones and confirm each log is still complete.

## What’s New in Version 3.1.3

- Rebuilt sharing around a join code you can read out, text, or tap. Invitation
  links that opened the app and did nothing are fixed, including from a cold
  start.
- Joining now brings your dining log with you, so both people see the same
  restaurants and outings while keeping their own reactions and rankings.
- Fixed a crash that could happen while a circle was being deleted.
- Removed the sync switches. Signing in keeps your log in your account, and
  there is no longer a local-only mode, a paused state, or a second circle to
  keep track of.
- Setup no longer asks for a circle name. Sharing appears only when you want it.
- Made it one tap for the owner to remove somebody from a circle, keeping
  everything that person logged.
- Leaving a circle now keeps your whole dining log and carries on syncing
  privately.
- Circle keys now travel in your iCloud Keychain, so a replacement iPhone can
  read your log again after signing in.
- Fixed mixed live-record and tombstone uploads so every bulk sync payload
  includes the required `payload` field and deletions are accepted by the
  production constraint.

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
   The `bigbeautifullog://` URL scheme registered in `project.yml` is the fallback
   when that file cannot be reached, so an invitation is never a dead link.
8. Test an invitation between two physical devices signed into different Apple
   Accounts: create, send, join, edit on both, delete on one, and confirm photos
   arrive on the second device.

There is no longer a schema to promote between environments. Adding an entity
means adding a `SyncKind` case; the `records` table is unchanged, so no
migration accompanies it.

## Permission behavior

- Location: When In Use only. There is no Always authorization or background visit detection in 3.1.3.
- Photos: the primary Backfill path uses PhotosPicker without library permission. The optional date-range scan requests read access.
- Notifications: no user-visible notifications are requested.

## Review notes

The dining log is kept in the person's own account, so setup asks for a name and
then offers Sign in with Apple. **A reviewer does not need an account to inspect
the app:** tapping **Sign in with Apple** and cancelling the system sheet reveals
**Continue Without an Account**, which completes setup with the log kept on the
device. From the final setup screen, **Preview with a sample Salt Lake log**
fills every primary screen with sample data.

Sharing a log with another person does require signing in, because the
invitation delivers an encryption key to a second account. No personal
information beyond the Apple-provided identifier and a display name is
requested, and Hide My Email is fully supported.
