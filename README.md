# Big Beautiful Restaurant Log

A private, native iPhone dining log for effortless meal logging, durable history, and rankings that behave like living predictions rather than permanent grades.

Product site: <https://realronaldrump.github.io/restaurant-ranking/>

Privacy policy: <https://realronaldrump.github.io/restaurant-ranking/privacy.html> · Support: <https://realronaldrump.github.io/restaurant-ranking/support.html>

## Product principles

- Every score is a living prediction.
- Every visit is permanent history.
- Every comparison is evidence rather than law.
- A complete rating takes only an establishment and one reaction.
- There is no feed, follower graph, engagement machinery, or analytics.
- Sharing runs through a sync service that holds only ciphertext; the log itself lives on the device.

## Architecture

- SwiftUI interface with per-tab `NavigationStack` navigation.
- Core Data via `NSPersistentContainer` as the local source of truth.
- End-to-end encrypted delta sync to Postgres for circle collaboration and shared visit rating (`RestaurantLog/Sync`).
- MapKit place search and foreground-only location guessing.
- PhotosPicker and PhotoKit backfill, processed on-device.
- A deterministic evidence-weighted ranking engine with absolute anchors, recency decay, confidence, comparison evidence, and a ±7 detail-adjustment cap.

Run `xcodegen generate`, open `Big Beautiful Restaurant Log.xcodeproj`, and select a development team.

To exercise circle syncing, follow [`supabase/README.md`](supabase/README.md) and put the project host and anon key in `Config/Supabase.local.xcconfig`. Without those the app builds and runs entirely on device with syncing switched off, which is how the simulator and the test suite run.

The reasoning behind the sync design, and what the service can and cannot see, is in [`docs/MIGRATION_PLAN.md`](docs/MIGRATION_PLAN.md).

The public source is provided for transparency. No license is granted beyond the rights supplied by applicable law or Apple’s Standard Licensed Application End User License Agreement for distributed app binaries.
