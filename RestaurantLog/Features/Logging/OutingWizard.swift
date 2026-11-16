import PhotosUI
import SwiftUI

/// Logging an outing as a full-screen run of taps: where, how it was, the
/// handful of things that shape its ranking, and then where it lands.
///
/// Nothing here is a form. Each screen asks one thing with big answers to
/// tap, moves on by itself, and can be stepped back to and changed. The
/// reaction tap saves the outing; everything after it is written as it is
/// answered, so the wizard can be left at any point.
@MainActor
struct LogMealFlow: View {
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    /// Skips straight to the reaction step for a known place, e.g. from Want to Try.
    var initialLocationID: UUID?
    @State private var model: OutingWizardModel?

    var body: some View {
        ZStack {
            WizardBackdrop()
            if let model { OutingWizard(model: model) }
        }
        .statusBarHidden()
        .task {
            guard model == nil else { return }
            let wizard = OutingWizardModel(
                store: store,
                locationService: locationService,
                initialLocationID: initialLocationID
            )
            wizard.start()
            model = wizard
        }
    }
}

@MainActor
private struct OutingWizard: View {
    @Bindable var model: OutingWizardModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    @State private var celebration = 0
    @State private var celebrationSize = 0
    @State private var editorVisit: VisitEntity?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                stepView
                    .id(model.step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(WizardPalette.cream)
        .sheet(item: $editorVisit) { visit in
            AddMoreVisitView(visit: visit, personID: model.savedPersonID, startsWithDetails: true)
        }
        .onChange(of: store.revision) { _, _ in
            wizardMove(reduceMotion) { model.reconcileRanking() }
        }
        .editorialPrompt(item: $model.duplicateOuting) { outing in
            guard outing.isAlive else {
                return EditorialPrompt(
                    "Outing unavailable",
                    message: "That shared outing was removed on another device.",
                    tone: .information,
                    actions: [.primary("Continue") { model.cancelDuplicate() }]
                )
            }
            let author = store.person(id: outing.createdByID)?.name ?? "Someone in your circle"
            return EditorialPrompt(
                "A shared outing already exists",
                message: "\(author) already logged \(outing.location?.name ?? "this restaurant") around this time and included you. Add your reaction to that outing instead?",
                tone: .decision,
                actions: [
                    .primary("Add my diner entry") { finish(model.resolveDuplicate(joining: outing)) },
                    .secondary("Keep as a separate outing") { finish(model.resolveDuplicate(joining: nil)) },
                    .cancel("Cancel") { model.cancelDuplicate() }
                ]
            )
        }
        // Keep decoration outside the prompt's accessibility modifiers so an
        // inactive prompt cannot expose its full-screen canvas to hit testing.
        .overlay {
            CelebrationBurst(trigger: celebration, particleCount: celebrationSize)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            leadingControl
                .frame(width: 44, height: 44)
            LogFlowProgress(step: model.stepIndex, count: model.steps.count)
                .frame(maxWidth: .infinity)
            trailingControl
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private var leadingControl: some View {
        if model.previousStep != nil {
            LogFlowIconButton(symbol: "chevron.left", label: "Back") {
                Haptics.tick()
                wizardMove(reduceMotion) { model.back() }
            }
            .accessibilityIdentifier("log-back")
        } else if !model.isSaved {
            LogFlowIconButton(symbol: "xmark", label: "Close") { dismiss() }
                .accessibilityIdentifier("log-close")
        } else if model.step == .place {
            // Reached by stepping back from a saved outing: leaving without
            // picking keeps the restaurant it already has.
            LogFlowIconButton(symbol: "chevron.right", label: "Keep this restaurant") {
                wizardMove(reduceMotion) { model.go(to: .reaction) }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if model.isSaved, model.step != .ranking, model.step != .place {
            Button {
                Haptics.tick()
                wizardMove(reduceMotion) { model.skipToRanking() }
            } label: {
                HStack(spacing: 4) {
                    Text("Rank it")
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .font(.callout.weight(.bold))
                .foregroundStyle(WizardPalette.redDeep)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(WizardPalette.card, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(BouncyPressStyle())
            .accessibilityHint("Skips the remaining questions")
            .accessibilityIdentifier("wizard-rank-it")
        }
    }

    /// The outgoing step falls back while the next one flies in from the side
    /// it was reached from. Only the arrival needs a direction: the departure
    /// was described before the direction was known.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: model.isMovingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .scale(scale: 0.9).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var stepView: some View {
        switch model.step {
        case .place:
            WizardPlaceStep(model: model)
        case .reaction:
            WizardReactionStep(model: model, finish: finish)
        case .dishes:
            WizardDishesStep(model: model, advance: advance)
        case .ranking:
            WizardRankingStep(
                model: model,
                celebrate: celebrate,
                openEditor: {
                    model.willOpenEditor()
                    editorVisit = model.savedVisit
                },
                done: { dismiss() }
            )
        case .clarity, .goBack, .value, .service, .vibe, .kind, .price, .occasion:
            WizardChoiceStep(model: model, step: model.step, advance: advance)
        }
    }

    private func advance() {
        wizardMove(reduceMotion) { model.advance() }
    }

    /// What happens once the reaction tap has been dealt with: a save is
    /// celebrated and the wizard moves on; anything else stays put.
    private func finish(_ outcome: OutingWizardModel.SaveOutcome) {
        guard outcome == .saved else { return }
        Haptics.success()
        celebrate(model.reaction?.celebrationSize ?? 0)
        advance()
    }

    private func celebrate(_ particles: Int) {
        guard !reduceMotion, particles > 0 else { return }
        celebrationSize = particles
        celebration += 1
    }
}

// MARK: - Shared pieces

/// The restaurant being logged, kept in view through the questions, with a
/// small arrow that flicks up or down when an answer moves its standing.
private struct WizardContextChip: View {
    let model: OutingWizardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownNudge: OutingWizardModel.NudgeEvent?

    var body: some View {
        HStack(spacing: 8) {
            if let reaction = model.reaction {
                Image(systemName: reaction.symbol).font(.footnote.weight(.bold))
            }
            Text(model.loggedLocation?.name ?? model.choice?.name ?? "")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let shownNudge {
                Image(systemName: shownNudge.direction == .up ? "arrow.up" : "arrow.down")
                    .font(.footnote.weight(.black))
                    .foregroundStyle(WizardPalette.redDeep)
                    .frame(width: 24, height: 24)
                    .background(WizardPalette.card, in: Circle())
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.3)
                            .combined(with: .offset(y: shownNudge.direction == .up ? 14 : -14))
                            .combined(with: .opacity),
                        removal: .opacity
                    ))
                    .id(shownNudge.id)
                    .accessibilityLabel(shownNudge.direction == .up ? "Nudged up" : "Nudged down")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(WizardPalette.cream.opacity(0.15), in: Capsule())
        .onChange(of: model.lastNudge) { _, nudge in
            guard let nudge else { return }
            if nudge.direction == .up { Haptics.tick() } else { Haptics.soft() }
            if reduceMotion { shownNudge = nudge }
            else { withAnimation(.spring(duration: 0.4, bounce: 0.5)) { shownNudge = nudge } }
            Task {
                try? await Task.sleep(for: .milliseconds(1300))
                guard shownNudge == nudge else { return }
                if reduceMotion { shownNudge = nil } else { withAnimation(.easeOut(duration: 0.3)) { shownNudge = nil } }
            }
        }
    }
}

private struct WizardTitle: View {
    let text: String
    var size: CGFloat = 42

    var body: some View {
        Text(text)
            .font(BBTheme.display(size, weight: .bold))
            .foregroundStyle(WizardPalette.cream)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The answers to one question: two giant cards stacked for a yes-or-no, or a
/// two-across grid for anything longer. It is laid out eagerly on purpose;
/// there are never more than a handful and a lazy grid has nothing to save.
private struct WizardOptionGrid: View {
    let options: [WizardOption]
    let selection: String?
    /// The answer tapped a moment ago, while the screen is still showing it.
    let justPicked: String?
    let identifierPrefix: String
    let hint: String?
    let pick: (WizardOption) -> Void

    private var layout: WizardOptionCard.Layout {
        options.count <= 2 ? .wide : (options.count > 4 ? .compact : .stacked)
    }

    var body: some View {
        let perRow = options.count <= 2 ? 1 : 2
        let rows = stride(from: 0, to: options.count, by: perRow).map {
            Array(options[$0..<min($0 + perRow, options.count)])
        }
        VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { columnIndex, option in
                        WizardOptionCard(
                            option: option,
                            isSelected: selection == option.id,
                            isPassedOver: justPicked != nil && justPicked != option.id,
                            layout: layout
                        ) { pick(option) }
                            .accessibilityIdentifier(identifierPrefix + option.id)
                            .accessibilityHint(hint ?? "")
                            .staggeredAppear(index: rowIndex * perRow + columnIndex)
                    }
                }
            }
        }
    }
}

/// A quiet text button on the red stage: Skip, Clear, Undo.
private struct WizardTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(WizardPalette.cream.opacity(0.82))
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Where

private struct WizardPlaceStep: View {
    @Bindable var model: OutingWizardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var photoItem: PhotosPickerItem?

    private static let tileColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Where?")
                    .font(BBTheme.display(52, weight: .bold))
                    .foregroundStyle(WizardPalette.cream)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    searchField
                    photoButton
                }
                photoStatus
                if model.trimmedQuery.isEmpty { suggestions } else { searchResults }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .readablePageWidth()
        }
        .scrollDismissesKeyboard(.immediately)
        .task(id: model.placeSearchKey) { await model.runMapSearch() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                await model.loadPhoto(item)
                photoItem = nil
                Haptics.selection()
            }
        }
    }

    private func pick(_ choice: PlaceChoice) {
        Haptics.snap()
        searchFocused = false
        wizardMove(reduceMotion) { model.select(choice) }
    }

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WizardPalette.ink.opacity(0.5))
            TextField("", text: $model.query, prompt: Text("Search").foregroundStyle(WizardPalette.ink.opacity(0.42)))
                .foregroundStyle(WizardPalette.ink)
                .tint(WizardPalette.red)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .accessibilityLabel("Search restaurants")
                .accessibilityIdentifier("log-place-search")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(WizardPalette.ink.opacity(0.4))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear search")
            }
        }
        .font(.body.weight(.medium))
        .padding(.leading, 15)
        .padding(.trailing, model.query.isEmpty ? 15 : 2)
        .frame(minHeight: 56)
        .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    private var photoButton: some View {
        let hasPhoto = model.mealPhoto != nil
        return PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .current) {
            Image(systemName: hasPhoto ? "photo.fill" : "photo.badge.plus")
                .font(.title3)
                .foregroundStyle(WizardPalette.red)
                .frame(width: 56, height: 56)
                .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        }
        .accessibilityLabel(hasPhoto ? "Replace photo" : "Start with a photo")
        .accessibilityHint("Uses the photo's date and location to fill in the outing")
        .accessibilityIdentifier("start-meal-with-photo")
    }

    @ViewBuilder
    private var photoStatus: some View {
        if model.isReadingPhoto {
            HStack(spacing: 10) {
                ProgressView().tint(WizardPalette.cream)
                Text("Reading photo…")
            }
            .font(.callout)
            .foregroundStyle(WizardPalette.cream.opacity(0.85))
        } else if let photo = model.mealPhoto {
            HStack(spacing: 12) {
                DraftMealPhoto(photo: photo)
                    .frame(width: 48, height: 48)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.captureDate == nil ? "No date in photo" : model.dateLabel)
                        .font(.callout.weight(.semibold))
                    Text(photo.coordinate == nil ? "No location in photo" : "Location found")
                        .font(.caption)
                        .foregroundStyle(WizardPalette.cream.opacity(0.75))
                }
                Spacer(minLength: 6)
                Button { model.clearPhoto() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(WizardPalette.cream.opacity(0.8))
                .accessibilityLabel("Remove photo")
            }
            .padding(.leading, 8)
            .padding(.vertical, 6)
            .background(WizardPalette.cream.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("photo-meal-context")
        } else if let error = model.photoError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        let groups = model.suggestionGroups
        nearbyStatus(isShowingNearby: groups.contains { $0.id == "nearby" })
        ForEach(groups) { group in
            let lead = group.leadsWithClosest ? group.suggestions.first : nil
            let rest = lead == nil ? group.suggestions : Array(group.suggestions.dropFirst())
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(group.title, color: WizardPalette.cream.opacity(0.85))
                if let lead {
                    LogPlaceTile(
                        name: lead.choice.name,
                        subtitle: lead.caption,
                        symbol: lead.choice.category.symbol,
                        isProminent: true
                    ) { pick(lead.choice) }
                        .staggeredAppear(index: 0)
                }
                if !rest.isEmpty {
                    LazyVGrid(columns: Self.tileColumns, spacing: 10) {
                        ForEach(Array(rest.enumerated()), id: \.element.id) { index, suggestion in
                            LogPlaceTile(
                                name: suggestion.choice.name,
                                subtitle: suggestion.caption,
                                symbol: suggestion.choice.category.symbol
                            ) { pick(suggestion.choice) }
                                .staggeredAppear(index: index + 1)
                        }
                    }
                }
            }
        }
        if groups.isEmpty, !model.isReadingPhoto {
            Text("Search for a place to add it.")
                .font(.callout)
                .foregroundStyle(WizardPalette.cream.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 28)
        }
    }

    /// The one line about location, shown only until nearby places take over.
    @ViewBuilder
    private func nearbyStatus(isShowingNearby: Bool) -> some View {
        if !isShowingNearby, model.mealPhoto?.coordinate == nil {
            switch model.locationService.authorization {
            case .notDetermined:
                VStack(spacing: 6) {
                    Button { model.requestNearby() } label: {
                        Label("Near me", systemImage: "location.fill")
                    }
                    .buttonStyle(WizardSecondaryButtonStyle())
                    .accessibilityIdentifier("show-nearby-restaurants")
                    Text("Only used while you pick.")
                        .font(.caption)
                        .foregroundStyle(WizardPalette.cream.opacity(0.75))
                }
            case .authorizedAlways, .authorizedWhenInUse:
                // Nothing is said about location unless this screen asked for
                // it; a failure is one tap away from another try.
                if !model.askedForNearby {
                    EmptyView()
                } else if model.locationService.errorMessage != nil {
                    Button { model.requestNearby() } label: {
                        Label("Nearby didn’t load. Try again", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(WizardPalette.cream.opacity(0.85))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("retry-nearby-restaurants")
                } else if model.locationService.isSearching || model.locationService.usableCurrentLocation == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(WizardPalette.cream)
                        Text("Looking nearby…")
                    }
                    .font(.footnote)
                    .foregroundStyle(WizardPalette.cream.opacity(0.85))
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let matches = model.searchMatches
        VStack(spacing: 8) {
            ForEach(matches.known) { choice in
                LogPlaceRow(name: choice.name, subtitle: choice.subtitle, symbol: choice.category.symbol, badge: "In your log") {
                    pick(choice)
                }
            }
            ForEach(matches.mapped) { choice in
                LogPlaceRow(
                    name: choice.name,
                    subtitle: choice.subtitle,
                    symbol: choice.category.symbol,
                    badge: choice.isInLog ? "In your log" : nil
                ) { pick(choice) }
            }
            if matches.mapped.isEmpty, model.locationService.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(WizardPalette.cream)
                    Text("Searching…")
                }
                .font(.footnote)
                .foregroundStyle(WizardPalette.cream.opacity(0.85))
                .frame(minHeight: 36)
            }
            LogPlaceRow(name: "Add “\(model.trimmedQuery)”", subtitle: "New restaurant", symbol: "plus") {
                pick(model.manualChoice)
            }
            .accessibilityIdentifier("manual-place-choice")
        }
    }
}

// MARK: - How was it

private struct WizardReactionStep: View {
    @Bindable var model: OutingWizardModel
    let finish: (OutingWizardModel.SaveOutcome) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPickingDate = false
    @State private var isCommitting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                WizardTitle(text: model.title(for: .reaction), size: 46)
                WizardOptionGrid(
                    options: model.options(for: .reaction),
                    selection: model.selection(for: .reaction),
                    justPicked: model.pendingReaction?.rawValue,
                    identifierPrefix: "reaction-",
                    hint: model.isSaved ? "Changes your reaction" : "Saves the outing",
                    pick: pick
                )
                .allowsHitTesting(!isCommitting)
                if !model.people.isEmpty, model.canEditOutingDetails { company }
                if let error = model.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                }
                if model.isSaved {
                    Button("Next") {
                        Haptics.tick()
                        wizardMove(reduceMotion) { model.advance() }
                    }
                    .buttonStyle(WizardSecondaryButtonStyle())
                    .accessibilityIdentifier("wizard-next")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .readablePageWidth()
        }
        .sheet(isPresented: $isPickingDate) { datePicker }
    }

    /// The tap is the save. The card gets a beat to show which answer was
    /// taken before the screen moves on.
    private func pick(_ option: WizardOption) {
        guard !isCommitting, let reaction = Reaction(rawValue: option.id) else { return }
        if model.isSaved, model.selection(for: .reaction) == option.id {
            Haptics.tick()
            wizardMove(reduceMotion) { model.advance() }
            return
        }
        Haptics.snap()
        isCommitting = true
        if reduceMotion { model.beginReaction(reaction) }
        else { withAnimation(.spring(duration: 0.32, bounce: 0.45)) { model.beginReaction(reaction) } }
        Task {
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(300)) }
            isCommitting = false
            guard model.step == .reaction, model.pendingReaction == reaction else { return }
            finish(model.commitPendingReaction())
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if let photo = model.mealPhoto {
                DraftMealPhoto(photo: photo)
                    .frame(width: 72, height: 72)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Text(model.loggedLocation?.name ?? model.choice?.name ?? "")
                .font(BBTheme.display(25))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.canEditOutingDetails { dateMenu }
        }
        .frame(maxWidth: .infinity)
    }

    /// The date is right almost every time, so it is a label that can be
    /// tapped rather than a field that has to be filled.
    private var dateMenu: some View {
        Menu {
            Button { model.setDay(daysAgo: 0) } label: { Label("Today", systemImage: "sun.max") }
            Button { model.setDay(daysAgo: 1) } label: { Label("Yesterday", systemImage: "moon") }
            Button { isPickingDate = true } label: { Label("Pick a date", systemImage: "calendar") }
            Button { model.setDate(nil) } label: { Label("Not sure when", systemImage: "questionmark") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(model.dateLabel)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(WizardPalette.cream)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(WizardPalette.cream.opacity(0.16), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("Outing date, \(model.dateLabel)")
        .accessibilityIdentifier("log-date-menu")
    }

    private var datePicker: some View {
        NavigationStack {
            DatePicker(
                "Outing date and time",
                selection: Binding(get: { model.visitDate }, set: { model.setDate($0) }),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .environment(
                \.calendar,
                DiningDateContext.calendar(offsetSeconds: model.visitTimeZoneOffsetSeconds)
            )
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("When?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { isPickingDate = false } }
            }
        }
        .presentationDetents([.fraction(0.72), .large])
        .presentationBackground(BBTheme.paper)
        .foregroundStyle(BBTheme.ink)
        .tint(BBTheme.oxblood)
    }

    private var company: some View {
        VStack(spacing: 10) {
            Eyebrow("With", color: WizardPalette.cream.opacity(0.85))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { companyChips }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { companyChips }
                }
            }
        }
    }

    @ViewBuilder
    private var companyChips: some View {
        ForEach(model.people) { person in
            let isSelected = model.companionIDs.contains(person.id)
            WizardChip(
                title: person.name,
                symbol: isSelected ? "checkmark.circle.fill" : "plus.circle",
                isSelected: isSelected
            ) {
                Haptics.selection()
                model.toggleCompanion(person.id)
            }
            .accessibilityIdentifier("visit-member-\(person.id.uuidString)")
        }
    }
}

// MARK: - One-tap questions

/// Every question with a fixed set of answers looks and behaves the same:
/// tap one and the wizard moves on.
private struct WizardChoiceStep: View {
    let model: OutingWizardModel
    let step: OutingWizardModel.Step
    let advance: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var justPicked: String?

    var body: some View {
        let options = model.options(for: step)
        let selection = model.selection(for: step)
        ScrollView {
            VStack(spacing: 22) {
                WizardContextChip(model: model)
                WizardTitle(text: model.title(for: step))
                    .padding(.top, 2)
                WizardOptionGrid(
                    options: options,
                    selection: selection,
                    justPicked: justPicked,
                    identifierPrefix: "wizard-option-",
                    hint: nil
                ) { pick($0, current: selection) }
                .allowsHitTesting(justPicked == nil)
                HStack(spacing: 6) {
                    if selection != nil {
                        WizardTextButton(title: "Clear") {
                            Haptics.tick()
                            wizardMove(reduceMotion) { model.answer(nil, for: step) }
                        }
                        .accessibilityIdentifier("wizard-clear")
                        WizardTextButton(title: "Next") { skip() }
                            .accessibilityIdentifier("wizard-next")
                    } else {
                        WizardTextButton(title: "Skip") { skip() }
                            .accessibilityIdentifier("wizard-skip")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .readablePageWidth()
        }
    }

    private func skip() {
        Haptics.tick()
        advance()
    }

    private func pick(_ option: WizardOption, current: String?) {
        guard justPicked == nil else { return }
        Haptics.snap()
        guard !reduceMotion else {
            if current != option.id { model.answer(option.id, for: step) }
            advance()
            return
        }
        withAnimation(.spring(duration: 0.3, bounce: 0.45)) {
            justPicked = option.id
            if current != option.id { model.answer(option.id, for: step) }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(290))
            guard !Task.isCancelled, model.step == step else { return }
            advance()
        }
    }
}

// MARK: - Dishes

private struct WizardDishesStep: View {
    let model: OutingWizardModel
    let advance: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var newDish = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let entries = model.dishEntries
        let suggestions = model.dishSuggestions
        ScrollView {
            VStack(spacing: 18) {
                WizardContextChip(model: model)
                WizardTitle(text: model.title(for: .dishes))
                addField
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions) { dish in
                                WizardChip(title: dish.name, symbol: "plus") { add(dish.name) }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.horizontal, -20)
                }
                VStack(spacing: 10) {
                    ForEach(entries) { entry in
                        dishRow(entry)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.85).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                Button {
                    Haptics.tick()
                    fieldFocused = false
                    advance()
                } label: {
                    Label(model.isEditingOneAnswer ? "Done" : "Rank it", systemImage: "arrow.right")
                }
                .buttonStyle(WizardPrimaryButtonStyle())
                .accessibilityIdentifier("wizard-next")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .readablePageWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var addField: some View {
        HStack(spacing: 8) {
            TextField("", text: $newDish, prompt: Text("Add a dish").foregroundStyle(WizardPalette.ink.opacity(0.42)))
                .foregroundStyle(WizardPalette.ink)
                .tint(WizardPalette.red)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($fieldFocused)
                .onSubmit {
                    add(newDish)
                    fieldFocused = !newDish.isEmpty
                }
                .accessibilityLabel("Dish name")
                .accessibilityIdentifier("wizard-dish-field")
            Button { add(newDish) } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(WizardPalette.card)
                    .frame(width: 44, height: 44)
                    .background(WizardPalette.red, in: Circle())
                    .opacity(newDish.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1)
            }
            .buttonStyle(BouncyPressStyle())
            .disabled(newDish.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Add dish")
            .accessibilityIdentifier("wizard-dish-add")
        }
        .font(.body.weight(.medium))
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: 56)
        .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    private func add(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Haptics.snap()
        wizardMove(reduceMotion) { model.addDish(named: name) }
        newDish = ""
    }

    private func dishRow(_ entry: DishEntryEntity) -> some View {
        HStack(spacing: 6) {
            Text(entry.dish?.name ?? "Dish")
                .font(.headline)
                .foregroundStyle(WizardPalette.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Reaction.allCases) { reaction in
                let isOn = entry.reaction == reaction
                let tint = WizardPalette.tint(reaction.wizardTone)
                Button {
                    Haptics.snap()
                    wizardMove(reduceMotion) { model.setReaction(reaction, for: entry) }
                } label: {
                    Image(systemName: reaction.symbol)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(isOn ? WizardPalette.card : tint)
                        .frame(width: 38, height: 38)
                        .background(isOn ? tint : tint.opacity(0.12), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BouncyPressStyle())
                .accessibilityLabel(reaction.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Button {
                Haptics.tick()
                wizardMove(reduceMotion) { model.removeDish(entry) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WizardPalette.ink.opacity(0.45))
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.dish?.name ?? "dish")")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 5)
    }
}

// MARK: - Where it lands

private struct WizardRankingStep: View {
    private enum Side { case mine, theirs }

    let model: OutingWizardModel
    let celebrate: (Int) -> Void
    let openEditor: () -> Void
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var pickedSide: Side?
    @State private var displayedScore = 0.0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let location = model.loggedLocation {
                    if let score = model.score {
                        hero(location, score)
                        RankLadder(rows: model.ladder)
                        if let opponent = model.activeOpponent {
                            faceOff(location, against: opponent)
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        } else {
                            settled
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        recap
                    } else {
                        notice(
                            location.name,
                            location.isClosed ? "Saved. Closed restaurants are not ranked." : "Saved. Not ranked yet."
                        )
                    }
                } else if model.isSaved {
                    notice("Outing unavailable", "It was removed on another device.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .readablePageWidth()
        }
        .accessibilityIdentifier("log-payoff")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear {
            guard let score = model.score, score.hasEarnedScore else { return }
            displayedScore = model.scoreBefore ?? 0
            roll(to: score.score, after: 0.3)
        }
        .onChange(of: model.score?.score) { _, value in
            if let value, model.score?.hasEarnedScore == true { roll(to: value, after: 0) }
        }
        .onChange(of: model.score?.hasEarnedScore) { old, new in
            guard old == false, new == true, let score = model.score else { return }
            // The number has just been earned: let it arrive like it matters.
            displayedScore = 0
            roll(to: score.score, after: 0.15)
            Haptics.success()
            celebrate(34)
        }
    }

    private func roll(to target: Double, after delay: Double) {
        if reduceMotion { displayedScore = target }
        else { withAnimation(.easeOut(duration: 0.9).delay(delay)) { displayedScore = target } }
    }

    private func notice(_ title: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44))
            Text(title).font(BBTheme.display(28)).multilineTextAlignment(.center)
            Text(message).font(.callout).foregroundStyle(WizardPalette.cream.opacity(0.8)).multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }

    // MARK: Hero

    private func hero(_ location: RestaurantLocation, _ score: LocationScore) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                if let reaction = model.reaction {
                    Image(systemName: reaction.symbol)
                        .font(.caption.weight(.bold))
                        .accessibilityLabel(reaction.title)
                }
                Eyebrow("Outing saved", color: WizardPalette.cream.opacity(0.9))
            }
            Text(location.name)
                .font(BBTheme.display(25))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("#\(score.categoryRank)")
                .font(BBTheme.display(82, weight: .bold))
                .contentTransition(.numericText(value: Double(score.categoryRank)))
                .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.4), value: score.categoryRank)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                .accessibilityLabel("Number \(score.categoryRank) in \(location.category.shortTitle)")
                .accessibilityIdentifier("log-rank")
            Text("in \(location.category.shortTitle)")
                .font(.headline)
                .foregroundStyle(WizardPalette.cream.opacity(0.85))
                .accessibilityHidden(true)
            scoreStatus(score)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    /// The score is shown once there is something behind it. Until then the
    /// same spot says what will unlock it, so the number is never an anchor
    /// dressed up as a measurement.
    @ViewBuilder
    private func scoreStatus(_ score: LocationScore) -> some View {
        if score.hasEarnedScore {
            HStack(spacing: 8) {
                RollingNumber(
                    value: displayedScore,
                    label: "Return score \(score.listScore) out of 100"
                )
                .font(BBTheme.score(24))
                Text("return score")
                    .font(.footnote.weight(.semibold))
                if let before = model.scoreBefore.map({ Int($0.rounded()) }), before != score.listScore {
                    HStack(spacing: 3) {
                        Image(systemName: score.listScore > before ? "arrow.up.right" : "arrow.down.right")
                            .accessibilityLabel(score.listScore > before ? "up" : "down")
                        Text("from \(before)")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(WizardPalette.cream.opacity(0.8))
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(WizardPalette.cream.opacity(0.16), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("log-score")
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        } else {
            let remaining = model.faceOffsToEarnScore
            let canFaceOff = model.activeOpponent != nil
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.footnote.weight(.bold))
                if canFaceOff {
                    HStack(spacing: 4) {
                        ForEach(0..<LocationScore.comparisonsToEarnScore, id: \.self) { index in
                            Circle()
                                .fill(WizardPalette.cream.opacity(index < LocationScore.comparisonsToEarnScore - remaining ? 1 : 0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                    Text(remaining == 1 ? "1 more face-off unlocks the score" : "\(remaining) face-offs unlock the score")
                } else {
                    Text("Score unlocks with more to compare")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(WizardPalette.cream.opacity(0.9))
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(WizardPalette.cream.opacity(0.16), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("log-score-locked")
            .transition(.opacity)
        }
    }

    // MARK: Face-off

    private func faceOff(_ location: RestaurantLocation, against opponent: RestaurantLocation) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Rather go back to…")
                    .font(BBTheme.display(22))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 5) {
                    ForEach(0..<OutingWizardModel.dialInRounds, id: \.self) { index in
                        Circle()
                            .fill(WizardPalette.cream.opacity(index <= model.round ? 1 : 0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Face-off \(min(model.round + 1, OutingWizardModel.dialInRounds)) of \(OutingWizardModel.dialInRounds)")
            }
            .padding(.top, 4)
            FaceOffCard(
                name: location.name,
                detail: "Just logged",
                symbol: location.category.symbol,
                verdict: verdict(for: .mine)
            ) { choose(.mine) }
                .accessibilityIdentifier("face-off-logged")
            FaceOffCard(
                name: opponent.name,
                detail: detail(for: opponent),
                symbol: opponent.category.symbol,
                verdict: verdict(for: .theirs)
            ) { choose(.theirs) }
                .accessibilityIdentifier("face-off-opponent")
                .id(opponent.id)
                .transition(opponentTransition)
            HStack(spacing: 14) {
                WizardTextButton(title: "Too close to call") {
                    Haptics.tick()
                    wizardMove(reduceMotion) { model.settle(.tie) }
                }
                .accessibilityHint("Records these restaurants as roughly even")
                WizardTextButton(title: "Skip") {
                    Haptics.tick()
                    wizardMove(reduceMotion) { model.skipOpponent() }
                }
                .accessibilityIdentifier("face-off-skip")
            }
            .disabled(pickedSide != nil)
        }
    }

    /// The outgoing challenger leaves in the direction the answer sent it: up
    /// the ranking if it was preferred, down if it was not.
    private var opponentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let departure: AnyTransition = switch pickedSide {
        case .theirs: .offset(y: -100)
        case .mine: .offset(y: 100)
        case nil: .move(edge: .leading)
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: departure.combined(with: .opacity)
        )
    }

    private func verdict(for side: Side) -> FaceOffCard.Verdict {
        guard let pickedSide else { return .undecided }
        return pickedSide == side ? .chosen : .passedOver
    }

    private func detail(for location: RestaurantLocation) -> String {
        var parts: [String] = []
        if let city = location.city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            parts.append(city)
        }
        if let last = location.visitArray.first(where: \.hasKnownDate) {
            parts.append("Last " + DiningDateContext.format(
                last.date,
                dateStyle: .short,
                timeStyle: .none,
                offsetSeconds: last.dateTimeZoneOffsetSeconds?.intValue
            ))
        }
        return parts.isEmpty ? location.category.shortTitle : parts.joined(separator: " · ")
    }

    private func choose(_ side: Side) {
        guard pickedSide == nil else { return }
        Haptics.impact()
        let outcome: ComparisonOutcome = side == .mine ? .a : .b
        if !reduceMotion {
            withAnimation(.spring(duration: 0.26, bounce: 0.45)) { pickedSide = side }
        }
        Task {
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(260)) }
            let rankBefore = model.score?.categoryRank
            let wasEarned = model.score?.hasEarnedScore ?? true
            wizardMove(reduceMotion) {
                model.settle(outcome)
                pickedSide = nil
            }
            guard let rankBefore, let rankAfter = model.score?.categoryRank else { return }
            if rankAfter < rankBefore {
                Haptics.thump()
                // Unlocking the score brings its own, bigger burst.
                if wasEarned == (model.score?.hasEarnedScore ?? true) { celebrate(18) }
            } else if rankAfter > rankBefore {
                Haptics.soft()
            }
        }
    }

    // MARK: After the face-offs

    @ViewBuilder
    private var settled: some View {
        VStack(spacing: 10) {
            if model.round > 0 {
                Label("Dialed in", systemImage: "checkmark.circle.fill")
                    .font(BBTheme.display(22))
            }
            if model.hasMoreToSettle {
                Button {
                    router.resetPath(for: .settle)
                    router.selectedTab = .settle
                    dismiss()
                } label: {
                    Label("Keep ranking", systemImage: "arrow.right")
                }
                .buttonStyle(WizardSecondaryButtonStyle())
                .accessibilityHint("Opens Settle the Score")
                .accessibilityIdentifier("log-keep-ranking")
            }
        }
        .padding(.top, 4)
    }

    /// Every answer given, each one a tap away from being changed.
    @ViewBuilder
    private var recap: some View {
        let items = model.recap
        VStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        WizardChip(title: item.title, symbol: item.symbol) { edit(item.step) }
                            .accessibilityHint("Changes this answer")
                    }
                    if let next = model.firstUnansweredStep {
                        WizardChip(title: "Add more", symbol: "plus") { edit(next) }
                            .accessibilityIdentifier("wizard-add-more")
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            if model.canUndo {
                WizardTextButton(title: "Undo this outing") {
                    Haptics.soft()
                    wizardMove(reduceMotion) { model.undoSave() }
                }
                .accessibilityHint("Removes the outing you just saved")
                .accessibilityIdentifier("log-undo")
            }
        }
        .padding(.top, 6)
    }

    private func edit(_ step: OutingWizardModel.Step) {
        Haptics.tick()
        wizardMove(reduceMotion) { model.edit(step) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let visit = model.savedVisit, visit.isAlive, let personID = model.savedPersonID,
               model.store.canEditDinerEntry(visit, personID: personID) {
                Button(action: openEditor) {
                    Label("Photos & notes", systemImage: "camera.fill")
                }
                .buttonStyle(WizardSecondaryButtonStyle())
                .accessibilityHint("Opens every detail of this outing")
                .accessibilityIdentifier("log-add-details")
            }
            Button("Done") {
                Haptics.tick()
                done()
            }
            .buttonStyle(WizardPrimaryButtonStyle())
            .accessibilityIdentifier("log-done")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [WizardPalette.redDeep.opacity(0), WizardPalette.redDeep.opacity(0.92)],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        )
    }
}
