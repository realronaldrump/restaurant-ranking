# Privacy Policy

**Effective July 29, 2026**

Big Beautiful Restaurant Log is designed to keep dining history private. There is no advertising, analytics, data broker, or tracking SDK, and the developer does not collect personal data from the app. Sharing a dining log with other people requires a sync service the developer operates, described below. That service stores dining records only in encrypted form and cannot read them.

Depending on the features used, the app handles restaurant names and locations, meal dates, ratings, comparisons, dishes, notes, companions, photos, and saved restaurants. Records are stored on the device using Apple Core Data. The app works fully without an account or a network connection.

Circle syncing is optional and off until the user turns it on. When it is on, each record and each photo is encrypted on the device using AES-GCM before it is uploaded to the sync service, which is hosted on Supabase. The encryption key is generated on the device, kept in the iOS Keychain, and shared with other circle members only inside an invitation the user sends directly to them. The key is never transmitted to or stored by the sync service, so the developer cannot read restaurant names, dates, ratings, dishes, notes, companions, photos, or circle names.

What the sync service can see is the structure around that content: how many records a circle holds and of which kinds, when they changed, which device wrote them, the size of each photo, and which accounts belong to which circle. Access to a circle’s rows is restricted by database row-level security to the accounts that belong to it.

Circle syncing requires Sign in with Apple, used only to identify which member a device belongs to. The app requests the email address Apple provides and stores nothing from the credential except the resulting session token, which is kept in the device Keychain. There is no password, profile, or contact list.

With permission, foreground location suggests nearby establishments. The app does not request Always location access or track location in the background. Search terms and coordinates may be sent to Apple through MapKit. Photo selection is optional; the system picker works without full-library permission. Optional backfill scanning requires read access for a chosen date range. Photo analysis occurs on-device, original photos remain unchanged, and app-stored copies are re-encoded without embedded GPS or EXIF metadata.

If the user imports a Beli data-export ZIP, the archive is parsed on-device. Restaurant names and cities may be sent to Apple through MapKit so the user can review location matches. Photo URLs contained in the export are requested directly from Beli's photo hosting service and the resulting app-stored copies are processed on-device. Account, email, phone, device, follower, and social-profile fields in the export are not retained by the app or sent to the developer.

The app contains no advertising SDK, analytics SDK, third-party tracking SDK, or cross-app tracking. The developer does not sell, rent, or use information for advertising or profiling.

Users can revoke Location and Photos permissions in iOS Settings, delete individual visits in the app, turn circle syncing off for a device, remove members from a circle, and export or erase all data from Settings. Records remain until the user deletes them. Because the developer never holds the encryption key, the developer cannot read, retrieve, or export a user’s dining records, and can only delete the encrypted rows themselves.

The app is a general-audience dining utility and is not directed to children under 13. If its data practices change, the hosted policy and App Store privacy disclosures will be updated.

The complete, controlling web version is published at <https://realronaldrump.github.io/restaurant-ranking/privacy.html>. Questions may be submitted through <https://realronaldrump.github.io/restaurant-ranking/support.html>. Public support requests must not include dining records, precise locations, account details, invitation links, personal photos, or other sensitive information. An invitation link contains a circle’s encryption key and must never be posted anywhere public.
