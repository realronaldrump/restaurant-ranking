# Big Beautiful Restaurant Log — Mental Model & UX Pass

Reviewed 2026-08-01 against 3.2 (build 20). Line references point at the tree as it stood then.

Method: full read of the SwiftUI surface layer + ranking engine, then a driven walkthrough on
iPhone 17 Pro (iOS 26.5) through onboarding, the seeded sample log, the log-an-outing loop,
outing/restaurant detail, Settle the Score, and Settings — in light mode, dark mode, and at
`accessibility-large` Dynamic Type.

## Implementation checklist

This checklist tracks the numbered findings below. Check an item only after the change is
implemented and verified against the current tree.

- [x] 1.1 Unify local-roster and sync visibility language
- [x] 1.2 Teach Outing versus Diner Entry without instructional eyebrow copy
- [x] 1.3 Replace “Provisional” dead ends and “Score Check” naming
- [x] 1.4 Make rank-number context explicit
- [x] 1.5 Make category ranking the default frame
- [x] 1.6 Represent visible score ties honestly
- [x] 1.7 Explain score movement on the payoff screen
- [x] 1.8 Remove score anchoring from comparison prompts and de-emphasize ties
- [x] 1.9 Explain circle disagreement without achievement styling
- [x] 2.1 Rebalance the tab bar around core product value
- [x] 2.2 Remove repetitive returning-user masthead furniture
- [x] 2.3 Use user-facing names and candidate-gate duplicate merging
- [x] 2.4 Simplify History scope/filter composition and copy
- [x] 3.1 Put common restaurant-selection paths before Photo First
- [x] 3.2 Keep the required reaction above the fold
- [x] 3.3 Make reaction selection/save behavior honest and recoverable
- [x] 3.4 Remove redundant and misleading step chrome
- [x] 3.5 Make the payoff explain the save and support repeat-visit refinement
- [x] 3.6 Align the follow-on button, destination, and cancellation semantics
- [x] 3.7 Ask for location permission only after an in-app rationale
- [x] 4.1 Split dark-mode oxblood ink and fill tokens
- [x] 4.2 Bring Form screens into the editorial visual language
- [x] 4.3 Make content names more prominent than scores
- [x] 4.4 Label reaction meaning and ownership without color alone
- [x] 4.5 Resolve the observed layout and navigation defects
- [x] 4.6 Use one possessive rule everywhere
- [x] 5.1 Make ranking rows reflow at accessibility text sizes
- [x] 5.2 Preserve display/body hierarchy as Dynamic Type grows
- [x] 5.3 Resolve smaller accessibility dead ends and missing visual encodings
- [x] 6.1 Fix More’s incorrect “Just you” status
- [x] 6.2 Make place-section empty cards fill available width
- [x] 6.3 Prevent restaurant-detail content clipping behind the CTA
- [x] 6.4 Replace the non-existent “Score Check” feature name
- [x] 6.5 Offer ranking refinement after repeat visits
- [x] 6.6 Remove the permanently empty reaction-selection affordance
- [x] 6.7 Keep an active onboarding session from exiting early

## Follow-up pass

A re-review of the implemented tree found four items that needed a second round, plus five
smaller inconsistencies the first pass introduced or left behind. All are now applied.

- [x] 5.2 (round two) **Restore an upper bound on display type.** The first fix replaced the
  absolute cap with a proportional floor, which removed the ceiling entirely — display sizes then
  tracked the body scale (roughly 3x at the largest accessibility size) with nothing opposing
  them. `BBTheme.scaled` now clamps both ends: `min(size * 1.9, max(titleScaled, floor))`.
- [x] 2.3 (round two) **Gate merging on real candidates instead of deleting the entry point.**
  Removing the More row left `AppRoute.merge` unreachable and `MergeLocationsView` dead. There is
  now `AppStore.duplicateLocationSuggestions()`, which surfaces only the ambiguous residue the
  automatic reconciliation pass deliberately declines to merge (same name with differing or
  missing addresses; near-identical names within 75 m). The merge screen leads with those
  suggestions and keeps manual selection behind a disclosure. Settings carries a permanent entry
  point; More shows a counted row only when suggestions exist.
- [x] 1.5 (round two) **Open on the category the person actually eats in.** Defaulting to the
  category holding the top overall spot could land on a one-restaurant list. The opening frame is
  now the densest category, falling back to Overall when nothing stands out.
- [x] 1.6 (round two) **Apply the rounding rule everywhere.** Statistics still rendered one
  decimal in list rows while Rankings rendered whole numbers. `LocationScore.listScore` and
  `CircleLocationScore.listScore` now own the rule and both screens use it.
- [x] Add a Back that withdraws the answer it undoes in Settle the Score, so a mistapped
  comparison leaves no evidence rather than needing a contradicting answer to argue it down
  (`AppStore.removeComparison(id:)`).
- [x] Precompute tied ranks once per snapshot instead of rescanning every row on each draw.
- [x] Use one label for the tie action across all four comparison surfaces.
- [x] Replace the system green in the score-change summary with the palette's `sage`.
- [x] Emit a typographic apostrophe in the generated circle name.

- [x] Close the payoff/list precision seam. The payoff screen quoted one decimal while every
  ranked list rounds, so it could announce a 0.3-point move the ranking then declined to show, or
  call a move "0.2 points" immediately before the list jumped a whole number. The payoff is where
  the mental model is taught, not a reference surface, so it now speaks the same whole numbers the
  ranking does and lets the rounded values decide what it claims happened — including an explicit
  "Still 84. This outing moved the prediction slightly, but not enough to change the number."

The restaurant detail hero keeps its decimal on purpose. That is the one surface where the
precise value earns its place: it is the only explanation available for why two restaurants
sharing a tied `=6` marker are ordered the way they are.

---

## 0. The headline

**The product philosophy and the interface disagree about what a score is.**

The README states the model plainly: *"Every score is a living prediction… every comparison is
evidence rather than law."* That is a genuinely good idea and it is what the ranking engine
actually implements — weighted means, recency decay, certainty, Elo-ish comparison passes,
a ±7 detail cap.

But the interface presents that prediction as a **scoreboard**:

- The number is the largest, boldest, most saturated element on every row of every list
  (`BBTheme.score(37)` vs a 21pt restaurant name in `RankingsView.rankingRow:230–248`).
- It is rendered to one decimal place everywhere (`.precision(.fractionLength(1))`).
- It never shows a delta, a direction, a range, or where it came from.

Everything users will find confusing downstream is a consequence of that single mismatch:

| What the user sees | What they conclude | What is actually true |
|---|---|---|
| `87.1` after **one** visit | "The app has measured this place precisely" | It's one reaction anchored at 85, nudged |
| `71.5`, `71.5`, `71.5` at ranks 6, 7, 8 | "The ranking is arbitrary / broken" | Real scores differ past the first decimal |
| Score drops 84.0 → 80.0 after a **good** visit | "I broke something" | Weighted mean of two visits; working correctly |
| "Food & overall 85" and "87.1" on one page | "Which is the score?" | Different aggregations, never reconciled |
| `PROVISIONAL` | "Something is wrong / incomplete" | Confidence state, no path to resolve it |

Fixing the visual grammar of the score is the highest-leverage change in the app, and it costs
nothing algorithmically.

---

## 1. Mental model breaks

### 1.1 "Who can see this?" — the app gives three different answers

This is the most serious issue, because it's a privacy question and the app answers it wrong on
the exact screen where users go to check.

With a local circle of two (Davis + Michelle, not signed in):

- **Log tab**: "SHARED DINING LOG · DAVIS' TABLE" / "A shared record of your circle's outings"
- **History**: "Circle" scope selector, "SHARED HISTORY"
- **Want to Try**: "SHARED SHORTLIST — Everyone in Davis' Table sees additions and removals"
- **Rankings**: Davis / Michelle / Circle scope picker
- **More**: **"YOUR DINING LOG — Just you"** — while displaying two member avatars

Cause: `MoreView:61-62` reads `sync.isShared` (`members.count > 1`, *server* memberships,
`SyncCoordinator:218`), while every other screen reads `store.circleMembers.count > 1` (the
*local* roster). Signed out, those disagree permanently.

There are genuinely two different concepts here (people in your log vs. devices syncing), and
both matter. But they need one vocabulary and one status line, stated the same way everywhere.

### 1.2 Outing vs. Diner Entry is a good model the UI never teaches

`CONTEXT.md` draws a careful distinction: an **Outing** is the shared real-world event; a
**Diner Entry** is one person's independent reaction. The data model honours it. The UI mostly
does too — but it explains the rule by putting an *instruction* into a label slot:

- `VisitDetailView:109` — eyebrow: "EACH PERSON RECORDS A REACTION ONLY FOR WHAT THEY TRIED",
  set as two lines of letterspaced all-caps
- `SharedVisitRatingView:52` — "Add only if you tried it too"
- `SharedVisitRatingView:89` — "Optional · your dishes only"

Eyebrows are 1–3 word labels. A sentence set in tracked uppercase is the hardest possible
rendering of instructional copy, and it repeats on every outing forever.

### 1.3 "Provisional" points at a feature that doesn't exist

`RankingsView:75` — the app's only explanation of provisional scores ends: *"…it becomes more
stable as you add outings or **run Score Check**."*

There is no "Score Check" in the app. The feature is called **Settle the Score**; "Score check"
appears only as an internal eyebrow on one of its two prompt types
(`SettleScoreView:65`, `GrandOpeningView:365`). The one instruction the app gives for resolving
its most confusing state names a destination the user cannot find.

Also: `PROVISIONAL` is a state with no call to action anywhere it appears. Tapping it does
nothing; the row offers no "add evidence" path.

### 1.4 Rank numbers silently change meaning

`RankingsView:363` — `displayedRank` returns `overallRank` when no category filter is active and
`categoryRank` when one is. Only the leader card's eyebrow reflects which list you're in
(`leaderRankLabel:371`); the numbered rows below change meaning with no label change at all.
A user filters to "Coffee & Tea", sees "1", and has no signal it isn't the same "1" they saw a
moment ago.

### 1.5 Cross-category ranking contradicts the user's question

The headline is "Where would you return?" but the default list is **overall**, so an ice-cream
shop out-ranks every restaurant. Users don't hold one ordered list spanning restaurants, bars,
bakeries and coffee shops — they hold several. The category ranks already exist in the engine;
they should probably be the default frame, with "overall" as the alternate.

### 1.6 Ties are shown as strict ordering

Ranks 6/7/8 all display `71.5`. The sort tiebreak is the *underlying* float, so the ordering is
real but invisible. Either show enough precision to justify the order, or show tied ranks as tied
(`=6`), or drop the decimal and rank by confidence.

### 1.7 The score moves with no explanation at the exact moment it matters

Logging a second "Liked It" at Central 9th Market took it 84.0 → 80.0. The payoff screen showed
`80.0 / current score / #1 in Counter Service` — no before/after, no direction, no reason.
`LogMealFlow.rankingInsertion:579` only narrates movement when the *rank* changes ("Moved from
#3 to #5"); a score change with a stable rank is silent.

This is the app's signature moment. It's the one place a "living prediction" could actually be
shown to live.

### 1.8 Comparison prompts show the answer before asking the question

`SettleScoreView.comparisonButton:107`, `LogMealFlow.quickChoice:574`,
`DirectComparisonView.choice:172`, `GrandOpeningView.calibrationChoice:504` all render the current
score on the choice button.

Pairwise comparison exists to collect evidence *independent* of the model, so the model can be
corrected. Displaying the model's current belief on the button anchors the response toward
confirming it. This measurably weakens the data the engine was designed around — and it's a
one-line fix in four places.

Compounding it: "Too Close to Call" is styled as the most prominent non-oxblood control and is
the lowest-effort answer, so it will be over-chosen — and a tie carries the weakest evidence
(step 2.4 vs 4.2, `RankingEngine:136`).

### 1.9 "Split Decision" is styled as an achievement

On the restaurant hero (`EstablishmentDetailView:154`), three chips sit in one row in two styles:
`#1 Dessert` (emphasized), `#1 overall` (muted), `Split Decision` (emphasized). Emphasis is
carrying two opposite meanings — "you're winning" and "your circle disagrees." Nothing on the
screen defines Split Decision (spread ≥ 15, `RankingEngine:59`), and it isn't tappable.

---

## 2. Information architecture

### 2.1 The tab bar spends its budget in the wrong places

**Want to Try** gets a full primary tab and was empty in the sample log. Behind **More** sit
seven destinations: Statistics, Settle the Score, Backfill, Merge Duplicates, Settings, Sharing,
and (via History) the Dining Atlas.

Settle the Score is the app's genuinely distinctive mechanic and it's a third-level row. Want to
Try is a bookmark list.

Consider: Log · Rankings · History · More, with Want to Try folded into History or Rankings as a
scope, and Settle the Score promoted.

### 2.2 Every tab announces itself three times

Log, Rankings, History and Want to Try each render: a tab-bar label, a nav-bar title, an eyebrow,
a large serif headline, and a descriptive subtitle. On Rankings that's **seven** stacked
elements before the first data row — the list starts ~64% down a 6.3" screen.

Measured cost of the marketing furniture:
- **Log**: masthead + tagline + stat row ≈ the top 45% of the screen, every launch, forever
- **Rankings**: eyebrow, headline, subtitle, info button, scope picker, filter strip, count
- **History**: eyebrow, headline, subtitle, count, scope segment, filter strip

The tagline copy ("A private record of the outings, restaurants, and opinions you want to
remember") is onboarding copy. A returning user reads it zero times and pays for it daily.

### 2.3 "Backfill" and "Merge Duplicates" are engineering words

`MoreView:26` — the row says **Backfill**. The destination it opens is headlined *"Find outings in
your photos"* (`BackfillView:38`). The good name is already written; it's just in the wrong place.

**Merge Duplicates** presents two `Picker`s over every restaurant with no detection, no
suggestions, and no preview (`MergeLocationsView:13-15`). It asks the user to do the app's job.
Either detect likely duplicates and propose them, or don't surface the tool until there's a
candidate.

### 2.4 History stacks two overlapping filter systems

A segmented `My Outings / Circle` control sits directly above a chip strip containing
`All / My Reaction Missing / My Hazy / Date Unknown / Shared / Closed`. "Shared" overlaps
conceptually with "Circle"; nothing explains how they compose. The chips are single-select but
styled as multi-select pills.

Copy: "My Hazy" isn't a phrase (adjective with the noun dropped) — "Hazy memory". "My Reaction
Missing" reads like a system message — "Not rated yet".

---

## 3. The core loop — logging an outing

The stated promise: *"A complete rating takes only an establishment and one reaction."* The flow
doesn't deliver on it.

### 3.1 Step 1 buries the common case under the rare one

Order on screen (`LogMealFlow.placePicker:158`): step chrome → headline → subtitle → search
field → **Photo First card (with the screen's only filled primary button)** → nearby → your
restaurants.

- "Start with a Photo" is the loudest control on the screen and is the *secondary* path.
- The Photo First card physically separates the search field from its own results.
- Nearby and your saved restaurants — the two most common picks — start below the fold.

### 3.2 Step 2 puts the one required input below the fold

Above the reaction picker: a 170pt decorative `CategoryArtwork`, the restaurant name, subtitle,
a "Who was there?" block with two lines of explanatory copy, and a date card whose first control
is a "Date unknown" toggle. On a 6.3" phone you must scroll to complete the primary action.

### 3.3 The reaction control lies about what it does

`LogMealFlow:471` — `ReactionPicker(selected: nil) { reaction in save(reaction) }`.

`selected` is hardwired to `nil`, so every option shows an empty radio circle that can never fill
in. It reads as "select, then confirm." Tapping it **saves the outing immediately and advances**.
There is no confirmation and no undo — to fix a mis-tap you go Done → History → find the outing →
Edit Outing.

The explanatory line "That's enough to save the outing" sits *below* the buttons, where it is
read only after acting.

Also: "It Was Fine" and "Not For Me" wrap to two lines while "Loved It" / "Liked It" don't, so
the 2×2 grid is visually ragged.

### 3.4 Redundant step chrome

`LOG AN OUTING · 1 OF 2` in the nav bar, and `QUICK LOG … 1 OF 2` with a progress bar 60pt below
it. Same information twice. And "1 of 2" is a promise the flow breaks — after step 2 come the
payoff screen and up to three comparison screens.

### 3.5 The payoff screen misses its own moment

- "OUTING SAVED" appears only as small nav-bar chrome; the content says "CURRENT RANKING".
- No score delta (see §1.7).
- `JUST AHEAD: None` — a labeled pedestal filled with the word "None".
- **"Refine Its Rank" never appears for a repeat visit.** `LogMealFlow:715` gates
  `quickQuestions` on `existing == nil`. A repeat visit is precisely when the score moves and
  comparison evidence would help most — and it's the one case that's excluded.

### 3.6 The follow-on button doesn't match its destination

"Add Dishes, Photos & Details" opens a screen titled **"Edit Outing"** whose first section is
**Restaurant / Change**. Dishes and photos are several sections down. Cancel is labelled
**"Not Now"**, which reads as dismissing a prompt rather than discarding edits (and it discards
typed dishes with no confirmation).

### 3.7 The location prompt fires cold

`LogMealFlow:111` calls `locationService.requestNearby()` in `.task`, so the system permission
alert appears the instant the user taps "Log an outing" — before they've asked for anything
location-shaped. The purpose string is good, but the in-app rationale ("Turn on location for
nearby results") is rendered *behind* the modal, invisible at decision time. This is the standard
recipe for a denial you can't recover from.

---

## 4. Visual design system

### 4.1 Dark mode breaks the brand

`Oxblood.colorset`: light `rgb(111, 29, 43)` → dark `rgb(199, 77, 97)`.

That's a rosy pink. It's a reasonable value for *text* on a dark ground, but the token is also
used as a **fill** — `PrimaryButtonStyle`, selected `FilterChip`, selected `ReactionPicker`,
the Log CTA card, every comparison button. Paired with `Paper` (which flips to near-black), the
primary button becomes **hot pink with black text**. The "printed page / editorial" identity
that the light theme earns is gone.

It also fails contrast: pink `#C74D61` behind near-black `#0E0F11` ≈ **4.2:1**, under the 4.5:1
AA threshold for the `.headline`-sized button text (17pt semibold doesn't qualify as large text).

Fix: split the token. `oxbloodInk` (text/accents, lightens in dark) and `oxbloodFill`
(surfaces, stays deep in dark, keeps cream text).

### 4.2 Form screens look like a different app

`AddMoreVisitView`, `SettingsView`, `EditLocationView`, `MergeLocationsView` and `AddWantView` use
SwiftUI `Form`, so rows render on **pure white** insetGrouped surfaces against the warm paper
background, with **gray uppercase system section headers** — while every other screen uses cream
`BBTheme.surface` cards with **oxblood `Eyebrow`** headers. Two visual languages, and the seam is
visible (in Edit Outing the reaction grid sits half in and half out of its section background,
butting directly against the white "Hazy memory" row).

### 4.3 The score out-shouts the content it describes

Per §0, and worth stating as a design rule: on every list row the number is set larger than the
restaurant name. In `RankingsView` the name gets `lineLimit(1)` and no `minimumScaleFactor` while
`ScoreMark` gets `minimumScaleFactor(0.7)` and a fixed trailing column — so **"Central 9th Mar…"
truncates at default text size** to protect a number that had room to shrink.

### 4.4 Reaction icons carry meaning that only the icon vocabulary explains

In history rows the verdict is a bare glyph with no label. `heart.fill` (Loved) vs
`hand.thumbsup.fill` (Liked) are distinguishable; `equal.circle.fill` (It Was Fine) and
`arrow.uturn.backward.circle.fill` (Not For Me) are not — and `arrow.uturn.backward`
conventionally means *undo*, not *wouldn't return*.

Worse, `VisitRow.reactionMark:280` distinguishes **your** verdict from **another diner's** with
colour alone (oxblood vs `.secondary`). That's a large semantic difference carried by a
non-accessible channel.

### 4.5 Layout defects observed

| Where | What |
|---|---|
| `LogMealFlow.placeSection:412` | Card doesn't stretch: the "NEARBY NOW / Looking around…" card rendered at ~40% width next to full-width cards. Needs `.frame(maxWidth: .infinity, alignment: .leading)`. |
| `EstablishmentDetailView:39,43` | `.padding(.bottom, 34)` vs a ~76pt `safeAreaInset` CTA — "Outing timeline" is permanently clipped behind the floating button. |
| `EstablishmentDetailView:249-257` | The map is tappable for directions but has `allowsHitTesting(false)` and no affordance, *and* there's a separate "Directions in Maps" button right below. Duplicate action, one invisible. |
| `EstablishmentDetailView` nav bar | No `navigationTitle` — scroll the hero away and there's no context. Same on `HomeView` (pushed screens show a bare "< Back"). |
| `VisitDetailView:144-148` | "VALUE / SERVICE / ATMOSPHERE — No reaction ×3" occupies a full row per diner even when nothing is set. |
| `VisitDetailView:219` | The "Coon is the dining mascot…" paragraph renders in full on **every** diner card with no stickers — 4 diners means 4 identical paragraphs, permanently. |
| `RankingsView:129` | Category chip strip clips mid-word ("Counter Servic…") with no scroll affordance. |

### 4.6 Two possessive rules, both visible

`AppStore.defaultCircleName:358` uses the trailing-s rule → **"Davis' Table"** (with a straight
apostrophe). `HomeView.mastheadPossessive:65` always appends `'S` → **"DAVIS'S DINING LOG"** (with
a typographic apostrophe). Both appear in the masthead depending on whether the log is shared, so
adding a second person changes the punctuation style of the user's own name.

---

## 5. Accessibility

### 5.1 The ranking list is unusable at accessibility text sizes — worst finding

At `accessibility-large`, **seven of eight** restaurant names truncate ("Eva's Bak…", "Tacos…",
"Central 9t…", "Publik Co…", "Fisher Br…", "Yoko Ram…") and every subtitle double-truncates
("Count… · Frie…", "Bars &… · Bre…"). The score renders at full size in a fixed trailing column
taking ~30% of the row.

The app sacrifices the identifying information to preserve the decorative number. Fix: let the
row reflow (`ViewThatFits` → vertical), give the name layout priority and a
`minimumScaleFactor`, and drop the decimal at large sizes.

### 5.2 Display type is capped while body type isn't

`BBTheme.scaled(_:cap:)` caps display/score fonts at 1.3–1.4×, but `.callout`/`.body` scale
fully. At AX sizes the 42pt masthead and the ~29pt tagline converge — the intended editorial
hierarchy flattens and inverts. On the Log tab at AX-large the primary CTA is clipped by the
screen edge mid-sentence ("Photo or restaurant, then…").

The cap is a reasonable instinct; the fix is to cap *proportionally* against the body scale
rather than absolutely, so the ratio survives.

### 5.3 Smaller items

- `EstablishmentDetailView.metricBar:319` — bar colour is the only encoding for "not rated"
  (`BBTheme.ink.opacity(0.12)`); the accessibility label is correct, the visual isn't.
- `ScoreMark`'s accessibility label says "out of 100" — but the visible UI never states the scale
  anywhere except inside the Settle the Score anchor ladder.
- Onboarding step 1: both CTAs are disabled at 0.4 opacity with **no explanation** that the name
  field is required. Disabled primary buttons with no stated cause are a dead end for anyone who
  doesn't guess.

---

## 6. Concrete bugs

1. **`MoreView` "Just you" vs. a multi-person circle** (§1.1) — wrong answer to a privacy
   question. Highest severity of the lot.
2. **`placeSection` empty-state card doesn't fill width** (§4.5) — visible on every cold open of
   the log flow.
3. **`EstablishmentDetailView` bottom inset clips content** (§4.5).
4. **"Score Check" names a non-existent feature** (§1.3).
5. **"Refine Its Rank" is unreachable for repeat visits** (§3.5) — arguably the highest-value
   comparison opportunity is the one excluded.
6. **`ReactionPicker(selected: nil)` renders a permanently empty selection affordance** (§3.3).
7. **Onboarding can be exited mid-flow when `didCompleteGrandOpening` is already true.**
   Observed on a simulator carrying that flag from an earlier install: the welcome screen showed,
   and the moment `bootstrap()` created a circle the app jumped straight to `MainTabView`,
   skipping the import and calibration steps.
   `RestaurantLogApp:61` ANDs two independently-settable conditions
   (`didCompleteGrandOpening && store.activeCircle != nil`), and three separate code paths set
   the flag (`:79`, `:117`, `:123`, `:166`). "Reset App" clears it correctly (`SettingsView:116`),
   so the reachable production path is narrow — a sync arriving mid-onboarding
   (`.circleDidArriveFromSync`) — but the coupling is fragile enough to be worth tightening.

---

## 7. What I'd do, in order

**Tier 1 — mental model (highest leverage, mostly copy and type)**

1. **Rebuild the score's visual grammar.** Name larger than number. Round to integers in lists,
   keep the decimal only on the detail hero. Replace the bare `PROVISIONAL` tag with an actionable
   confidence cue ("1 visit · tap to add evidence"). Show tied scores as tied.
2. **Show the delta on the payoff screen.** `84.0 → 80.0 ▾` with one line of plain why:
   "Two visits now average out. Your first was Loved It." This is the single change that would
   teach the entire model.
3. **Unify the sharing status.** One `isShared` source of truth, one status line, stated
   identically on Log / More / Settings / Want to Try. Fix `MoreView` first.
4. **Stop showing scores on comparison buttons.** Four call sites; makes every comparison the
   engine ingests meaningfully better.
5. **Fix "Score Check" → "Settle the Score"** and link it from the provisional explanation.

**Tier 2 — the core loop**

6. Reorder step 1: search → nearby → your restaurants → "or start with a photo" as a quiet row.
7. Move the reaction picker above the fold on step 2; collapse "Who was there?" and the date card
   behind a single "Add details" disclosure.
8. Give the reaction picker honest affordances — remove the dead radio circles, or hold selection
   and add an explicit Save with an undo path.
9. Drop the duplicated step chrome; keep one indicator.
10. Offer "Refine Its Rank" on repeat visits.
11. Add an in-app rationale before the location prompt.

**Tier 3 — accessibility & system**

12. Make ranking rows reflow at AX sizes; prioritise the name over the number.
13. Split the oxblood token into ink and fill variants for dark mode.
14. Bring `Form` screens onto the editorial surface/eyebrow language.
15. Add labels (not just colour) to reaction marks in list rows.

**Tier 4 — IA**

16. Reconsider the fifth tab: promote Settle the Score, demote Want to Try.
17. Trim the per-tab masthead furniture; move taglines to empty states only.
18. Rename Backfill to the name its own destination already uses.
19. Give Merge Duplicates actual duplicate detection, or hide it until there's a candidate.
