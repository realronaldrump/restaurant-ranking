# Dining Log

This context describes how a private circle records shared restaurant outings while preserving each diner’s independent experience and ranking evidence.

## Language

**Circle**:
A private shared dining log containing members, restaurants, outings, and rankings.
_Avoid_: Group, account

**Restaurant**:
A canonical place in a circle that can hold outing history, Want to Try state, and ranking evidence. A restaurant may exist without an outing when someone saves or ranks a familiar place first.
_Avoid_: Venue, establishment record

**Outing**:
One real-world visit to a restaurant that may include multiple diners.
_Avoid_: Meal, duplicate visit

**Participant**:
A person associated with an outing, including their attendance and rating-response state.
_Avoid_: Tag, companion when referring to a circle member

**Diner Entry**:
One participant’s independent reaction, dishes, memory, and photos for an outing.
_Avoid_: Shared meal, shared plate

**Dish**:
A canonical menu item at a restaurant.

**Dish Entry**:
One participant’s reaction to a dish they personally tried during an outing.
_Avoid_: Dish reaction without an owner

**Ranking Answer**:
One participant’s comparison between restaurants or score anchor for a familiar restaurant. It is evidence about a restaurant, not outing history.

## Relationships

- A **Circle** contains many **Restaurants** and **Outings**
- A **Restaurant** contains zero or more **Outings**
- An **Outing** belongs to exactly one **Restaurant**
- An **Outing** contains one or more **Participants**
- A **Participant** contributes at most one **Diner Entry** to an **Outing**
- A **Diner Entry** can contain many **Dish Entries**
- A **Dish Entry** belongs to exactly one participant and one canonical **Dish**
- A **Ranking Answer** references one or two existing **Restaurants**

## Deletion lifecycle

- Deleting an **Outing** removes that event and its diner entries, dish entries, and photos; it does not implicitly delete its **Restaurant**
- When the final **Outing** is deleted, removing the now-empty **Restaurant** is a separate explicit choice
- A **Restaurant** can be removed only when it has no outings, including when its outings were deleted in an older app version
- Removing a **Restaurant** also removes its Want to Try state and every **Ranking Answer** that references it, because that evidence has no meaning without the restaurant

## Ownership and access

- Circle membership makes an **Outing** visible; it does not make every circle member a **Participant**
- Only the person who logged an **Outing** can edit or delete its shared restaurant, date, details, and participant list
- A recorded **Participant** can add or edit only their own **Diner Entry**
- Someone who is not a participant, including a person marked **not there**, has read-only access to the outing

## Example dialogue

> **Dev:** “George and Michelle independently logged the same dinner. Should those be two outings?”
> **Domain expert:** “No. Reconcile them into one **Outing**, then preserve George’s and Michelle’s separate **Diner Entries**.”

## Flagged ambiguities

- “visit” previously meant both the shared real-world outing and one person’s submission — resolved: **Outing** is shared; **Diner Entry** is personal.
- “tag” previously implied both visibility and attendance — resolved: circle sharing controls visibility; a **Participant** records attendance and response state.
