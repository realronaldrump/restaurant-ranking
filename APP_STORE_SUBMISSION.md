# App Store submission checklist

## Product identity

- Product: Big Beautiful Restaurant Log
- Bundle identifier: `com.davis.bigbeautifulranking`
- iCloud container: `iCloud.com.davis.bigbeautifulranking`
- Version: 2.6 (build 8)
- Devices: iPhone only
- Minimum OS: iOS 17.0

## App Privacy answers

Select **Data Not Collected**. The developer receives no user data. Dining records and photos are processed locally and may be stored in the user’s own private or explicitly shared iCloud databases. Apple’s guidance distinguishes data processed only on-device and data handled by Apple frameworks from data collected by the developer.

- Tracking: No
- Third-party advertising: No
- Developer advertising or marketing: No
- Analytics: No
- Data brokers: No
- Third-party SDKs: ZIPFoundation, used only to read user-selected Beli ZIP exports. It contains no advertising, analytics, tracking, accounts, or network service.

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

## What’s New in Version 2.6

- Fix a launch crash affecting TestFlight builds by correcting the production CloudKit configuration.
- Show the app immediately while its private iCloud dining log finishes loading, eliminating the prolonged black screen on first launch.
- Display the installed version and release date in Settings.

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
2. Enable iCloud and CloudKit.
3. Attach container `iCloud.com.davis.bigbeautifulranking`.
4. Enable Push Notifications for CloudKit silent changes.
5. Set the Xcode project’s Development Team.
6. Run once against the Development CloudKit environment.
7. Exercise every entity and relationship, then deploy the CloudKit schema to Production in CloudKit Console.
8. Test CKShare invitation acceptance between two physical devices signed into different iCloud accounts.

For version 2.5, confirm the participant, import-session, import-link, unknown-date, photo-caption, and comparison evidence-fingerprint fields exist in the Development schema before promoting it to Production.

## Permission behavior

- Location: When In Use only. There is no Always authorization or background visit detection in 1.0.
- Photos: the primary Backfill path uses PhotosPicker without library permission. The optional date-range scan requests read access.
- Notifications: no user-visible notifications are requested.

## Review notes

The app has no developer account system. Sign-in and sharing use the user’s existing iCloud account. A reviewer can choose “Preview with a sample Salt Lake log” during the Grand Opening to inspect every primary screen without entering personal data.
