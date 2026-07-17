# App Store submission checklist

## Product identity

- Product: Big Beautiful Restaurant Log
- Bundle identifier: `com.davis.bigbeautifulranking`
- iCloud container: `iCloud.com.davis.bigbeautifulranking`
- Version: 1.0.1 (build 3)
- Devices: iPhone only
- Minimum OS: iOS 17.0

## App Privacy answers

Select **Data Not Collected**. The developer receives no user data. Dining records and photos are processed locally and may be stored in the user’s own private or explicitly shared iCloud databases. Apple’s guidance distinguishes data processed only on-device and data handled by Apple frameworks from data collected by the developer.

- Tracking: No
- Third-party advertising: No
- Developer advertising or marketing: No
- Analytics: No
- Data brokers: No
- Third-party SDKs: None

The bundled `PrivacyInfo.xcprivacy` declares no collection or tracking and declares `CA92.1` for app-scoped `UserDefaults`, which stores only device-local circle identity, selected ledger, onboarding completion, and haptic preference.

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

## Capabilities to configure in the Apple Developer portal

1. Create or select App ID `com.davis.bigbeautifulranking`.
2. Enable iCloud and CloudKit.
3. Attach container `iCloud.com.davis.bigbeautifulranking`.
4. Enable Push Notifications for CloudKit silent changes.
5. Set the Xcode project’s Development Team.
6. Run once against the Development CloudKit environment.
7. Exercise every entity and relationship, then deploy the CloudKit schema to Production in CloudKit Console.
8. Test CKShare invitation acceptance between two physical devices signed into different iCloud accounts.

## Permission behavior

- Location: When In Use only. There is no Always authorization or background visit detection in 1.0.
- Photos: the primary Backfill path uses PhotosPicker without library permission. The optional date-range scan requests read access.
- Notifications: no user-visible notifications are requested.

## Review notes

The app has no developer account system. Sign-in and sharing use the user’s existing iCloud account. A reviewer can choose “Preview with a sample Salt Lake ledger” during the Grand Opening to inspect every primary screen without entering personal data.
