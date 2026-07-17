# Big Beautiful Restaurant Log

A private, native iPhone dining ledger for effortless meal logging, durable history, and rankings that behave like living predictions rather than permanent grades.

Product site: <https://realronaldrump.github.io/restaurant-ranking/>

Privacy policy: <https://realronaldrump.github.io/restaurant-ranking/privacy.html> · Support: <https://realronaldrump.github.io/restaurant-ranking/support.html>

## Product principles

- Every score is a living prediction.
- Every visit is permanent history.
- Every comparison is evidence rather than law.
- A complete rating takes only an establishment and one reaction.
- There is no feed, follower graph, engagement machinery, analytics, or hosted backend.

## Architecture

- SwiftUI interface with per-tab `NavigationStack` navigation.
- Core Data via `NSPersistentCloudKitContainer`, with private and shared CloudKit store descriptions.
- `CKShare` circle collaboration and shared visit rating.
- MapKit place search and foreground-only location guessing.
- PhotosPicker and PhotoKit backfill, processed on-device.
- A deterministic evidence-weighted ranking engine with absolute anchors, recency decay, confidence, comparison evidence, and a ±7 detail-adjustment cap.

Run `xcodegen generate`, open `BigBeautiful.xcodeproj`, select a development team, and provide a CloudKit container matching `iCloud.com.davis.bigbeautifulranking` before testing iCloud sharing on devices.

The app runs without iCloud in a local fallback store for simulator development and automated tests.

The public source is provided for transparency. No license is granted beyond the rights supplied by applicable law or Apple’s Standard Licensed Application End User License Agreement for distributed app binaries.
