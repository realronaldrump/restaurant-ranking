# Privacy Policy

**Effective August 1, 2026**

Big Beautiful Restaurant Log is designed to keep dining history private. There is no advertising, analytics, data broker, or tracking SDK. The app works locally without an account. Optional circle syncing uses a developer-operated service, described below, that stores dining records only in encrypted form and cannot read them.

Depending on the features used, the app handles restaurant names and locations, meal dates, ratings, comparisons, dishes, notes, companions, photos, and saved restaurants. Records are stored on the device using Apple Core Data. The app works fully without an account or a network connection.

Circle syncing is optional and off until the user turns it on. When it is on, each record and each photo is encrypted on the device using AES-GCM before it is uploaded to the sync service, which is hosted on Supabase. The encryption key is generated on the device, kept in the iOS Keychain, and shared with other circle members only inside an invitation the user sends directly to them. The key is never transmitted to or stored by the sync service, so the developer cannot read restaurant names, dates, ratings, dishes, notes, companions, photos, or circle names.

What the sync service can see is the structure around that content: how many records a circle holds and of which kinds, when they changed, an app-generated device identifier, the size of each photo, and which accounts belong to which circle. Access to a circle’s rows is restricted by database row-level security to the accounts that belong to it.

Circle syncing requires Sign in with Apple, used only to identify which member a device belongs to. Supabase Auth stores the Apple-derived user identifier and email address Apple provides, which may be a private relay address. The resulting refresh token is kept in the device Keychain. There is no app password, public profile, or contact list. Supabase may process ordinary request metadata such as IP address and user agent to operate and secure the service.

With permission, foreground location suggests nearby establishments. The app does not request Always location access or track location in the background. Search terms and coordinates may be sent to Apple through MapKit. Coordinates saved with restaurants or meals may also be included in encrypted sync records when circle syncing is on; the sync service cannot decrypt them. Photo selection is optional; the system picker works without full-library permission. Optional backfill scanning requires read access for a chosen date range. Photo analysis occurs on-device, original photos remain unchanged, and app-stored copies are re-encoded without embedded GPS or EXIF metadata.

If the user imports a Beli data-export ZIP, the archive is parsed on-device. Restaurant names and cities may be sent to Apple through MapKit so the user can review location matches. Photo URLs contained in the export are requested directly from Beli's photo hosting service and the resulting app-stored copies are processed on-device. Account, email, phone, device, follower, and social-profile fields in the export are not retained by the app or sent to the developer.

The app contains no advertising SDK, analytics SDK, third-party tracking SDK, or cross-app tracking. The developer does not sell, rent, or use information for advertising or profiling.

Users can revoke Location and Photos permissions in iOS Settings; delete individual visits; turn syncing off; sign out; remove a member; leave a circle; have an owner permanently delete a circle’s encrypted service records and photo objects; and delete the sync account and all service data it owns. Local records remain until the user deletes them or resets the app. The developer cannot read, retrieve in readable form, or export synced dining content because the service never receives the circle key.

The app is a general-audience dining utility and is not directed to children under 13. If its data practices change, the hosted policy and App Store privacy disclosures will be updated.

The complete, controlling web version is published at <https://realronaldrump.github.io/restaurant-ranking/privacy.html>. Questions may be submitted through <https://realronaldrump.github.io/restaurant-ranking/support.html>. Public support requests must not include dining records, precise locations, account details, invitation links, personal photos, or other sensitive information. An invitation link contains a circle’s encryption key and must never be posted anywhere public.
