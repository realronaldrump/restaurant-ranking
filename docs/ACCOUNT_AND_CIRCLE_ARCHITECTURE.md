# Accounts, circles, and joining

## The model

Three nouns, and nothing else:

| | |
| --- | --- |
| **You** | One account, one person record, one name. Set at setup and never asked about again. Meals are always logged as you. |
| **Your circle** | The people who share your dining log. The only way in is a join code. Until somebody uses one, there is no circle to think about. |
| **People you dine with** | Names you can tag on an outing. They do not need the app and tagging one shares nothing. |

**One device, one dining log.** A circle is not a container you pick between —
it *is* your log, plus whoever else is in it. The app never holds a second
circle, never asks whether syncing is on, and never leaves records where the
other members cannot see them.

Four rules follow from that:

1. **Signed in means synced.** There is no switch. Signing in with Apple
   registers the log, generates its key, uploads it encrypted, and keeps it up
   to date. A log that is only sometimes published is what made two members
   disagree about what the circle contained.
2. **Sharing is opt-in and invisible until used.** Somebody logging their own
   meals never sees circle machinery: no circle name at setup, no roster, no
   invitations. The moment they send a code, the log becomes a circle.
3. **Joining merges.** Accepting a code moves this iPhone's restaurants,
   outings, ratings, comparisons, wish list and imports into the circle being
   joined. Somebody who joins and then imports a restaurant list expects the
   others to see it, so the log follows the person.
4. **Leaving never deletes.** Leaving, being removed, or an owner stopping
   sharing all keep every local record. The log is given a fresh circle
   identity and carries on syncing privately.

Rule 4 is also a stability rule. Version 3.0.2 crashed while deleting a circle:
SwiftUI re-evaluated a row for a `CircleEntity` that Core Data had already
invalidated, and reading `id` off it trapped inside
`UUID._unconditionallyBridgeFromObjectiveC`. Nothing in circle management
deletes a local object graph any more, the store filters every collection the
interface reads through `NSManagedObject.isAlive`, and the member list is
rendered from plain values rather than live managed objects.

### What was removed, and why

The previous build had two parallel notions of "member": a local person profile
somebody typed in, and an account that had accepted an invitation, linked by a
`person_id`. Inviting meant picking a profile first, which is where invitations
became unredeemable, rosters went stale, and "add a circle member" produced
somebody who was in the circle but could not see it. Now a member is an account
that used a code, full stop, and the joiner brings their own profile.

The same build asked which member was using the iPhone, so one device could log
for several people. Nobody does that. Meals are always logged as you; tagging
somebody in your circle invites *them* to add their own entry on their own
phone, which the pending-entry prompt on the home screen already handles.

## Joining

The invitation is a twelve-character join code — `K7M4-2QPX-9WTR` — in Crockford
base32, so it can be read aloud, typed, texted, or tapped as a link. There is
one mechanism with several front doors, rather than a link that has to work.

```
inviter                                service                         joiner
───────                                ───────                         ──────
code = random 60 bits
wrap circle key with
PBKDF2(code, salt, 200k)    ──▶ store sha256(code),
                                salt, sealed envelope
                                                          ◀── redeem sha256(code)
                                (insert membership and
                                 return envelope in one
                                 transaction)             ──▶ unwrap with code,
                                                              store circle key
```

The service holds the code's hash and an envelope it cannot open. It can match a
redemption without ever being able to read the circle, and a database disclosure
does not hand anybody a dining log. Membership and envelope delivery happen in
one transaction, so nobody can end up a member of a circle they cannot decrypt.

Delivery paths, all equivalent:

| Path | Notes |
| --- | --- |
| Typed or pasted in the app | The primary path. Needs nothing but the code. |
| `https://realronaldrump.github.io/restaurant-ranking/join#CODE` | Universal link. The code sits in the fragment, so it never reaches the web server. |
| `bigbeautifullog://join/CODE` | Fallback scheme for when the association file cannot be reached. |

An invitation that arrives during launch is held as router state and presented
when the interface exists, rather than pushed at whatever happened to be on
screen. That is what previously made a tapped link open the app and appear to do
nothing.

## Membership

- Any member may invite. Every member can already read and write every record in
  the circle, so requiring the owner bought no protection.
- The joiner claims their own person record as they accept.
  `set_circle_member_person` repairs the link if two devices later converge on
  one profile for the same human, and `adoptDeviceIdentity(preferring:)` uses
  the service's answer to re-establish which profile this account logs as after
  a reinstall. Neither ever asks the person a question.
- The owner removes somebody with one button. Service access is revoked first;
  the local profile is then demoted to a taggable name, keeping their outings,
  or removed outright if it has no history.
- Removing a member never rewrites shared history.

## Keys and recovery

Circle keys are stored as **synchronizable** Keychain items, so they follow the
person's iCloud Keychain to a replacement iPhone. Without that, signing in on a
new device downloads a log it can never decrypt and the only recovery is asking
another member for a code. The sync service still never sees a key: iCloud
Keychain is end-to-end encrypted to the Apple Account. The Supabase refresh
token stays device-only, because signing in again re-obtains it.

## Service surface

Everything lives in `supabase/migrations`, with RLS enabled and forced and
mutations behind narrowly scoped RPCs. `0010_join_codes.sql` adds
`create_join_code`, `redeem_join_code`, `set_circle_member_person`, and
`revoke_join_codes`; the 3.0.2 functions are left in place so an installed build
keeps working until it is replaced.

## Verification

Two accounts on two devices, exercising: invite, redeem, and confirm each side
sees the other's restaurants and rankings; a second redemption of a used code is
refused; an expired code is refused; an envelope replayed against another circle
fails to open; removal revokes service access while leaving history intact;
leaving keeps the local log and resumes syncing under a new circle; and a
non-member select returns zero rows.
