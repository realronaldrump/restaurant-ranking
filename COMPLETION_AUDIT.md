# Version 1.0 completion audit

This is the evidence map for the frozen Revision 2 product brief. “Implemented” means source exists and the production target plus test target compile. Runtime-only and account-dependent gates remain explicitly separate.

## Core experience

- Implemented: three-tap log, foreground nearby guess, MapKit search, manual fallback, automatic save, and ranking-position payoff (`Features/Logging/LogMealFlow.swift`).
- Implemented: optional new-place placement asks no more than three within-category questions; every question supports skip and Too Close to Call. Return visits ask none by default.
- Implemented: complete Add More sheet with dishes, photos, visit type, subratings, price, occasion, circle members, reusable named companions, reorder intent, hazy memory, and the single narrative Memory field.
- Implemented: unrated visits remain in history without ranking influence.

## Ranking engine

- Implemented: 0–100 one-decimal scores, four fixed reaction anchors, Bayesian-style certainty, recency decay, established-place movement guardrail, dish prediction, comparison evidence, ties, anchor evidence, provisional state, category ranks, overall ranks, and couple averages (`Ranking/RankingEngine.swift`).
- Implemented: optional details are capped at ±7, with dish/food evidence strongest, value next, and service/atmosphere least.
- Implemented: Settle the Score generates up to five uncertainty-driven prompts and includes shared-scale anchor calibration without initiated cross-category duels.
- Implemented: direct comparisons may be cross-category because they are explicitly volunteered.
- Test evidence: `RankingEngineTests.swift` covers anchors, detail cap, three-year recency, unrated visits, stability, clustering, identity, companions, and merge behavior.

## Records and retrieval

- Implemented: normalized Circle, Person, Brand, Location, Visit, Rating, Dish, DishEntry, Photo, Comparison, and WantEntry Core Data entities.
- Implemented: fixed establishment-page hierarchy, dish honors, timeline, photo viewer, breakdown, sparkline, and practical MapKit details.
- Implemented: searchable history includes place, city, dish, companion, and memory text.
- Implemented: full establishment editing, Closed behavior, and duplicate merge with visit, dish, Want to Try, and comparison reassignment.

## Sharing

- Implemented: private and shared `NSPersistentCloudKitContainer` stores, persistent history, remote changes, CKShare creation/acceptance, and cross-store object assignment.
- Implemented: device-local active-circle and current-person selection prevents one person’s `isMe` state from contaminating another person’s ranking.
- Implemented: shared pending-visit cards and independent overall/dish reactions.
- External verification required: invite acceptance and bidirectional mutation must be tested on two physical devices using different iCloud accounts after the developer configures the CloudKit container.

## Backfill

- Implemented: PhotosPicker primary path without library permission, optional PhotoKit date-range scan, on-device EXIF/GPS parsing, two-hour/500-foot clustering, exact 150-meter automatic place lookup, explicit confirmation, Not a Meal, Skip, and immediate unrated/hazy/full rating choices.
- Implemented: original files remain untouched; app copies are re-encoded at source dimensions without GPS/EXIF metadata.

## Privacy and distribution

- Implemented: no analytics, ads, account server, or third-party SDKs.
- Implemented: foreground-only location permission, optional photo permission, privacy policy source page, App Privacy manifest, app icon, entitlements, and App Store submission checklist.
- External configuration required: Apple Developer team, App ID, CloudKit container/schema promotion, Push Notifications capability, support details, and a stable public HTTPS host for `docs/privacy.html`.

## Build evidence

- iOS Simulator application build: succeeded.
- Full unit-test bundle build: succeeded.
- End-to-end UI-test bundle build: succeeded. It covers seeded launch, all primary tabs, ranking lenses, three-tap logging, payoff, history persistence, and minimum home-screen hit targets.
- Xcode static analysis: succeeded.
- Info.plist, entitlements, and PrivacyInfo.xcprivacy: valid.
- Built app contains the privacy manifest and compiled iPhone icon assets.
- Runtime evidence: all 12 unit tests and all 3 end-to-end UI tests pass on iPhone 17 Pro (iOS 26.3.1 simulator).
- Visual evidence: the seeded ledger was reviewed at iPhone 17 Pro dimensions; masthead, meal CTA, ranking table, touch targets, tab bar, and scroll behavior render cleanly.
- Distribution scope: iPhone only. iPad, Mac Catalyst, and Designed for iPhone on Mac are disabled in project settings.
