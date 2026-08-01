import CoreLocation
import PhotosUI
import SwiftUI
import UIKit

private struct PlaceChoice: Identifiable {
    enum Source { case existing(RestaurantLocation), map(PlaceCandidate), manual(String) }
    let source: Source
    let id: String
    let name: String
    let subtitle: String
    let category: DiningCategory
}

private struct PlaceSearchKey: Hashable {
    let query: String
    let latitude: Double?
    let longitude: Double?
}

private extension RestaurantLocation {
    var placeChoice: PlaceChoice {
        let cleanAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCity = city?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = if let cleanAddress, !cleanAddress.isEmpty {
            cleanAddress
        } else {
            [category.shortTitle, cleanCity].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        }
        return .init(source: .existing(self), id: "existing-\(id)", name: name, subtitle: detail, category: category)
    }

    func matchesPlaceQuery(_ query: String) -> Bool {
        query.isEmpty || [name, address, city]
            .compactMap { $0 }
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
    }
}

@MainActor
struct LogMealFlow: View {
    private enum Stage { case place, reaction, payoff, quickComparisons }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    /// Skips straight to the reaction step for a known place, e.g. from Want to Try.
    var initialLocationID: UUID?
    @State private var stage: Stage = .place
    @State private var choice: PlaceChoice?
    @State private var query = ""
    @State private var mapResults: [PlaceCandidate] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var mealPhoto: BackfillPhoto?
    @State private var photoMapResults: [PlaceCandidate] = []
    @State private var photoSuggestionToConfirm: PlaceChoice?
    @State private var isReadingPhoto = false
    @State private var photoError: String?
    @State private var saveError: String?
    @State private var photoRequestID = UUID()
    @State private var visitDate = Date.now
    @State private var visitDateKnowledge: VisitDateKnowledge = .known
    @State private var selectedReaction: Reaction?
    @State private var detailsExpanded = false
    @State private var savedVisit: VisitEntity?
    @State private var savedScore: LocationScore?
    @State private var scoreBeforeSave: Double?
    @State private var priorRatedVisitCount = 0
    @State private var priorReaction: Reaction?
    @State private var savedReaction: Reaction?
    @State private var oldRank: Int?
    @State private var taggedMemberIDs: Set<UUID> = []
    @State private var duplicateOuting: VisitEntity?
    @State private var duplicateReaction: Reaction?
    @State private var addMoreVisit: VisitEntity?
    @State private var quickQuestions: [ComparisonQuestion] = []
    @State private var quickIndex = 0
    @State private var payoffAppeared = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .place: placePicker
                case .reaction: reactionPicker
                case .payoff: payoff
                case .quickComparisons: quickComparison
                }
            }
            .editorialPage()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if stage != .payoff {
                        Button(leadingButtonTitle, action: handleLeadingButton)
                    }
                }
                ToolbarItem(placement: .principal) { Eyebrow(stageTitle) }
            }
        }
        .sheet(item: $addMoreVisit) { visit in
            AddMoreVisitView(visit: visit, personID: store.currentPerson?.id, startsWithDetails: true)
        }
        .onChange(of: selectedPhotoItem) { _, item in
            Task { await loadMealPhoto(item) }
        }
        .task {
            if let initialLocationID, choice == nil,
               let location = store.locations.first(where: { $0.id == initialLocationID }) {
                choice = location.placeChoice
                stage = .reaction
            }
            guard !ProcessInfo.processInfo.arguments.contains("-resetForUITests") else { return }
            requestNearbyIfAlreadyAuthorized()
        }
        .editorialPrompt(item: $duplicateOuting) { outing in
            guard outing.isAlive else {
                return EditorialPrompt(
                    "Outing unavailable",
                    message: "That shared outing was removed on another device.",
                    tone: .information,
                    actions: [.primary("Continue") { clearDuplicateChoice() }]
                )
            }
            let author = store.person(id: outing.createdByID)?.name ?? "Someone in your circle"
            return EditorialPrompt(
                "A shared outing already exists",
                message: "\(author) already logged \(outing.location?.name ?? "this restaurant") around this time and included you. Add your reaction to that outing instead?",
                tone: .decision,
                actions: [
                    .primary("Add my diner entry") { join(outing) },
                    .secondary("Keep as a separate outing") {
                        guard let reaction = duplicateReaction else { return }
                        clearDuplicateChoice()
                        saveNewVisit(reaction)
                    },
                    .cancel("Cancel") { clearDuplicateChoice() }
                ]
            )
        }
        .editorialPrompt(item: $photoSuggestionToConfirm) { suggestion in
            EditorialPrompt(
                "Confirm restaurant",
                message: "\(suggestion.name)\n\(suggestion.subtitle)\n\nThe closest map match to your photo. Confirm only if the address is right.",
                tone: .decision,
                actions: [
                    .primary("Use this restaurant") { select(suggestion) },
                    .cancel("Choose another restaurant")
                ]
            )
        }
    }

    private var stageTitle: String {
        switch stage {
        case .place: "Restaurant · 1 of 2"
        case .reaction: "Reaction · 2 of 2"
        case .payoff: "Outing saved"
        case .quickComparisons: "Optional comparisons"
        }
    }

    private var leadingButtonTitle: String {
        switch stage { case .place: "Cancel"; case .reaction: "Back"; case .payoff: "Done"; case .quickComparisons: "Back" }
    }

    private func handleLeadingButton() {
        switch stage {
        case .place:
            dismiss()
        case .reaction:
            stage = .place
        case .quickComparisons:
            refreshPayoff()
            stage = .payoff
        case .payoff:
            break
        }
    }

    private var placePicker: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Where did you eat?")
                        .font(BBTheme.display(37))
                    Text(mealPhoto == nil ? "Search by name, pick a nearby restaurant, or choose one from your log." : "Check the photo details, then confirm the restaurant.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                searchField
                if !trimmedQuery.isEmpty {
                    placeSection("Your restaurants", choices: existingChoices, empty: nil)
                    placeSection("Map results", choices: mapChoices, empty: locationService.isSearching ? "Searching…" : "No map matches yet.")
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("Not listed?")
                        Button { select(manualChoice) } label: {
                            Label("Create “\(trimmedQuery)” as a new restaurant", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("manual-place-choice")
                    }
                    .editorialCard(padding: 12)
                } else if mealPhoto != nil {
                    photoFirstCard
                    photoPlaceSuggestions
                    placeSection("Your restaurants", choices: Array(existingChoices.prefix(8)), empty: "Your saved restaurants will appear here.")
                } else {
                    nearbySection
                    placeSection("Your restaurants", choices: Array(existingChoices.prefix(8)), empty: "Your saved restaurants will appear here.")
                    photoFirstCard
                }
            }.padding(20).readablePageWidth()
        }
        .task(id: placeSearchKey) {
            guard !trimmedQuery.isEmpty else { mapResults = []; return }
            guard !ProcessInfo.processInfo.arguments.contains("-resetForUITests") else {
                mapResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            mapResults = await locationService.search(trimmedQuery, around: mealPhoto?.coordinate)
        }
    }

    @ViewBuilder
    private var photoFirstCard: some View {
        if let mealPhoto {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .topLeading) {
                    DraftMealPhoto(photo: mealPhoto)
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                        .clipped()
                    Eyebrow("Photo selected")
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .background(BBTheme.paper.opacity(0.94))
                        .padding(10)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label(mealPhoto.captureDate == nil ? "Check the date and time" : "Date and time from the photo", systemImage: "calendar")
                        .font(.callout.weight(.semibold))
                    DatePicker(
                        "Outing date and time",
                        selection: $visitDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("photo-meal-date")
                    Text(mealPhoto.captureDate == nil ? "The photo had no date, so today is filled in. You can change it." : "Taken from the photo. You can change it before saving.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Label(
                        mealPhoto.coordinate == nil ? "No location in photo" : "Location found in photo",
                        systemImage: mealPhoto.coordinate == nil ? "location.slash" : "location.fill"
                    )
                    .font(.callout.weight(.semibold))
                    Spacer()
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        Text("Replace")
                            .font(.callout.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    Button("Remove") { clearMealPhoto() }
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }

                Text("The saved copy is resized, and its location data is removed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .editorialCard(padding: 14)
            .accessibilityIdentifier("photo-meal-context")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title3)
                            .foregroundStyle(BBTheme.oxblood)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Or start with a photo")
                                .font(.headline)
                                .foregroundStyle(BBTheme.ink)
                            Text("Its date and location can fill in the details.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("start-meal-with-photo")
                if isReadingPhoto {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the photo’s date and location…")
                    }
                    .font(.callout)
                }
                if let photoError {
                    Label(photoError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(BBTheme.oxblood)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .editorialCard(padding: 12)
        }
    }

    @ViewBuilder
    private var photoPlaceSuggestions: some View {
        if isReadingPhoto {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for restaurants near the photo…")
            }
            .font(.callout)
            .frame(minHeight: 48)
        } else if mealPhoto?.coordinate == nil {
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow("Restaurant")
                Text("This photo has no location. Search by name or pick one from your log.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let suggestion = photoChoices.first {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Closest match")
                Button { photoSuggestionToConfirm = suggestion } label: {
                    HStack(spacing: 13) {
                        Image(systemName: suggestion.category.symbol)
                            .font(.title3)
                            .foregroundStyle(BBTheme.cream)
                            .frame(width: 38, height: 38)
                            .background(BBTheme.cream.opacity(0.13), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.name).font(BBTheme.display(23))
                            Text(suggestion.subtitle).font(.caption).foregroundStyle(BBTheme.cream.opacity(0.75)).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .padding(16)
                    .foregroundStyle(BBTheme.cream)
                    .background(BBTheme.oxbloodFill)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityHint("Asks you to confirm the name and address before selecting it.")
                .accessibilityIdentifier("photo-place-suggestion")
                Text("This comes from an Apple Maps search around the photo’s location, not from the photo itself. Tap only if it looks right.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                let alternatives = Array(photoChoices.dropFirst().prefix(5))
                if !alternatives.isEmpty {
                    placeSection("Other restaurants near the photo", choices: alternatives, empty: nil)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow("Restaurant")
                Text("Nothing close enough to suggest. Search for it below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search restaurants and cafés", text: $query)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary).accessibilityLabel("Clear search") }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(BBTheme.surface, in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                .stroke(BBTheme.hairline)
        }
        .accessibilityIdentifier("log-place-search")
    }

    private var placeSearchKey: PlaceSearchKey {
        .init(
            query: query,
            latitude: mealPhoto?.coordinate?.latitude,
            longitude: mealPhoto?.coordinate?.longitude
        )
    }

    private func placeSection(_ title: String, choices: [PlaceChoice], empty: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            if choices.isEmpty, let empty { Text(empty).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12) }
            ForEach(choices) { choice in
                Button { select(choice) } label: {
                    HStack(spacing: 13) {
                        Image(systemName: choice.category.symbol).foregroundStyle(BBTheme.oxblood).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.name).font(.headline).foregroundStyle(BBTheme.ink)
                            Text(choice.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if choice.id != choices.last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .editorialCard(padding: 12)
    }

    private var reactionPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let choice {
                    HStack(spacing: 14) {
                        if let mealPhoto {
                            DraftMealPhoto(photo: mealPhoto)
                                .frame(width: 76, height: 76)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
                        } else {
                            Image(systemName: choice.category.symbol)
                                .font(.title2)
                                .foregroundStyle(BBTheme.oxblood)
                                .frame(width: 54, height: 54)
                                .background(BBTheme.oxblood.opacity(0.08), in: Circle())
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.name)
                                .font(BBTheme.display(29))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(choice.subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Label(
                                visitDate.formatted(date: .abbreviated, time: .shortened),
                                systemImage: "calendar"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .editorialCard(padding: 12)

                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow("Your reaction · required")
                        Text("Pick one, then tap Save outing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ReactionPicker(selected: selectedReaction) { reaction in
                            selectedReaction = reaction
                            Haptics.selection()
                        }
                        Button("Save outing") {
                            guard let selectedReaction else { return }
                            save(selectedReaction)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(selectedReaction == nil)
                        .accessibilityIdentifier("save-outing")
                        if let saveError {
                            Label(saveError, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(BBTheme.oxblood)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    DisclosureGroup(isExpanded: $detailsExpanded) {
                        VStack(alignment: .leading, spacing: 16) {
                            if !store.otherCircleMembers.isEmpty { circleMemberTags }
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Date unknown", isOn: Binding(
                                    get: { visitDateKnowledge == .unknown },
                                    set: { visitDateKnowledge = $0 ? .unknown : .known }
                                ))
                                if visitDateKnowledge == .known {
                                    DatePicker("Outing date and time", selection: $visitDate, displayedComponents: [.date, .hourAndMinute])
                                }
                            }
                        }
                        .padding(.top, 14)
                    } label: {
                        Label("Add people or change details", systemImage: "slider.horizontal.3")
                            .font(.headline)
                    }
                    .accessibilityIdentifier("log-optional-details")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .editorialCard(padding: 14)
                }
            }
            .padding(20)
            .readablePageWidth()
        }
    }

    private var circleMemberTags: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Who was there?")
            Text("People in your circle can add their own reaction to this outing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.otherCircleMembers) { person in
                        let isSelected = taggedMemberIDs.contains(person.id)
                        Button {
                            if isSelected { taggedMemberIDs.remove(person.id) }
                            else { taggedMemberIDs.insert(person.id) }
                            Haptics.selection()
                        } label: {
                            Label(person.name, systemImage: isSelected ? "checkmark.circle.fill" : "person.crop.circle")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .foregroundStyle(isSelected ? BBTheme.cream : BBTheme.ink)
                                .background(isSelected ? BBTheme.oxbloodFill : BBTheme.ink.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("visit-member-\(person.id.uuidString)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var payoff: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 16)
                if let visit = savedVisit, visit.isAlive, let location = visit.location, let score = savedScore {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(BBTheme.oxblood)
                        Eyebrow("Outing saved")
                        Text(location.name).font(BBTheme.display(35)).multilineTextAlignment(.center)
                        ScoreMark(score: score.score, caption: "return score", size: 74, provisional: score.isProvisional)
                    }
                    .padding(.bottom, 4)
                    .scaleEffect(payoffAppeared ? 1 : 0.85)
                    .opacity(payoffAppeared ? 1 : 0)
                    scoreChangeSummary(score)
                    rankingInsertion(score)
                    if !quickQuestions.isEmpty {
                        Button { quickIndex = 0; stage = .quickComparisons } label: {
                            Label("Compare", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Add outing details") { addMoreVisit = visit }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Done") { dismiss() }.font(.headline).frame(minHeight: 48)
                }
                Spacer(minLength: 20)
            }.padding(20).readablePageWidth()
        }
        .onAppear {
            if reduceMotion { payoffAppeared = true }
            else { withAnimation(.spring(duration: 0.55, bounce: 0.3)) { payoffAppeared = true } }
        }
        .accessibilityIdentifier("log-payoff")
    }

    private var quickComparison: some View {
        ScrollView {
            if quickIndex >= quickQuestions.count {
                VStack(spacing: 18) {
                    Spacer(minLength: 12)
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 54, weight: .light)).foregroundStyle(BBTheme.oxblood)
                    Eyebrow("Done")
                    Text("Ranking updated").font(BBTheme.display(34)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Back to the return score") { refreshPayoff(); stage = .payoff }.buttonStyle(PrimaryButtonStyle())
                    Spacer(minLength: 12)
                }.padding(22).readablePageWidth()
            } else {
                let question = quickQuestions[quickIndex]
                VStack(spacing: 18) {
                    HStack { Eyebrow("Optional \(quickIndex + 1) of \(quickQuestions.count)"); Spacer() }
                    Spacer(minLength: 12)
                    Text("Which would you rather go back to?").font(BBTheme.display(33)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    quickChoice(question.a, outcome: .a, question: question)
                    Text("OR").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                    quickChoice(question.b, outcome: .b, question: question)
                    HStack(spacing: 22) {
                        Button("Too close to call") { recordQuick(.tie, question: question) }
                        Button("Skip") { quickIndex += 1 }
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    Button("Finish now") { refreshPayoff(); stage = .payoff }.font(.callout).foregroundStyle(.secondary).frame(minHeight: 44)
                }.padding(22).padding(.bottom, 12).readablePageWidth()
            }
        }
    }

    private func quickChoice(_ location: RestaurantLocation, outcome: ComparisonOutcome, question: ComparisonQuestion) -> some View {
        Button { recordQuick(outcome, question: question) } label: {
            HStack {
                Image(systemName: location.category.symbol)
                Text(location.name).font(BBTheme.display(22))
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(18)
            .foregroundStyle(BBTheme.cream)
            .background(BBTheme.oxbloodFill)
        }.buttonStyle(.pressable)
    }

    /// Describes the move in the same whole numbers the ranking shows.
    ///
    /// The engine works in fractions, but the ranking rounds, so quoting the
    /// precise delta here would announce a change the list then declines to
    /// show — or call a move "0.2 points" right before the list jumps a whole
    /// number. Both readings are avoided by letting the rounded values, not the
    /// raw ones, decide what this screen claims happened.
    private struct ScoreMove {
        let before: Int
        let after: Int
        let nudgedWithinTheSameNumber: Bool

        var didMove: Bool { before != after }
        var isIncrease: Bool { after > before }

        init(from before: Double, to after: Double) {
            self.before = Int(before.rounded())
            self.after = Int(after.rounded())
            nudgedWithinTheSameNumber = self.before == self.after && abs(after - before) >= 0.05
        }

        var summary: String {
            if didMove {
                let size = abs(after - before)
                return "\(isIncrease ? "Up" : "Down") \(size) \(size == 1 ? "point" : "points")."
            }
            if nudgedWithinTheSameNumber {
                return "Still \(after). This outing nudged the score, but not enough to change the number."
            }
            return "The score held steady."
        }
    }

    private func scoreChangeSummary(_ score: LocationScore) -> some View {
        VStack(spacing: 8) {
            if let scoreBeforeSave {
                let move = ScoreMove(from: scoreBeforeSave, to: score.score)
                HStack(spacing: 8) {
                    Text("\(move.before)")
                    Image(systemName: "arrow.right")
                        .accessibilityLabel("to")
                    Text("\(move.after)")
                    if move.didMove {
                        Image(systemName: move.isIncrease ? "arrow.up.right" : "arrow.down.right")
                            .foregroundStyle(move.isIncrease ? BBTheme.sage : BBTheme.oxblood)
                            .accessibilityLabel(move.isIncrease ? "increased" : "decreased")
                    }
                }
                .font(.headline.monospacedDigit())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Return score \(move.before) to \(move.after)")
                Text(move.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This is its starting score.")
                    .font(.headline)
            }
            Text(scoreExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .editorialCard(padding: 14)
    }

    private var scoreExplanation: String {
        let current = savedReaction?.title.lowercased() ?? "new"
        if scoreBeforeSave == nil {
            return "Your reaction, “\(current)”, sets the starting score. More outings and comparisons will move it."
        }
        if priorRatedVisitCount == 1, let priorReaction {
            return "This score now blends two outings: “\(priorReaction.title.lowercased())” last time and “\(current)” this time."
        }
        if priorRatedVisitCount > 1 {
            return "This score now blends “\(current)” with your \(priorRatedVisitCount) earlier outings here."
        }
        return "This score now blends “\(current)” with your earlier outings and comparisons here."
    }

    private func rankingInsertion(_ score: LocationScore) -> some View {
        let categoryScores = store.ranked().filter { $0.location.category == score.location.category }
        let above = categoryScores.first { $0.categoryRank == score.categoryRank - 1 }
        let below = categoryScores.first { $0.categoryRank == score.categoryRank + 1 }
        return VStack(spacing: 12) {
            RankChip(text: "#\(score.categoryRank) in \(score.location.category.shortTitle)", emphasized: true)
            if let oldRank, oldRank != score.categoryRank {
                Text("Moved from #\(oldRank) to #\(score.categoryRank)").font(.callout.weight(.semibold))
            } else if oldRank == nil { Text("Added to your ranking.").font(BBTheme.display(18, weight: .regular)) }
            if above != nil || below != nil {
                HStack(spacing: 14) {
                    if let above { neighbor(above, label: "Just ahead") }
                    if above != nil, below != nil { Divider().frame(height: 50) }
                    if let below { neighbor(below, label: "Just behind") }
                }
            }
        }.editorialCard()
    }

    private func neighbor(_ score: LocationScore, label: String) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(score.location.name).font(.callout.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var nearbySection: some View {
        if locationService.authorization == .notDetermined {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Nearby restaurants")
                Text("See what is around you")
                    .font(.headline)
                Text("Your location is only used while you pick a restaurant. You can always search instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    locationService.requestNearby()
                } label: {
                    Label("Show nearby restaurants", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("show-nearby-restaurants")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .editorialCard(padding: 14)
        } else {
            placeSection("Nearby now", choices: nearbyChoices, empty: nearbyEmptyMessage)
        }
    }

    private func requestNearbyIfAlreadyAuthorized() {
        switch locationService.authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            locationService.requestNearby()
        default:
            break
        }
    }

    private var nearbyEmptyMessage: String {
        if let errorMessage = locationService.errorMessage { return errorMessage }
        return switch locationService.authorization {
        case .denied, .restricted: "Location is off. You can still search."
        case .notDetermined: "Tap Show nearby restaurants to use your location."
        default: locationService.isSearching || locationService.usableCurrentLocation == nil ? "Looking around…" : "No nearby matches. Search below."
        }
    }

    private var existingChoices: [PlaceChoice] {
        store.locations.filter { !$0.isClosed && $0.matchesPlaceQuery(trimmedQuery) }.map(\.placeChoice)
    }
    private var nearbyChoices: [PlaceChoice] { locationService.nearby.map(choice(for:)) }
    private var mapChoices: [PlaceChoice] { mapResults.map(choice(for:)) }
    private var photoChoices: [PlaceChoice] {
        guard let coordinate = mealPhoto?.coordinate else { return [] }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let existing = store.locations.compactMap { location -> (PlaceChoice, CLLocationDistance)? in
            guard !location.isClosed, let value = location.coordinate else { return nil }
            let distance = origin.distance(from: CLLocation(latitude: value.latitude, longitude: value.longitude))
            guard distance <= MealPhotoDraftPolicy.restaurantLookupRadius else { return nil }
            return (location.placeChoice, distance)
        }
        let mapped = photoMapResults.map { candidate in
            (
                choice(for: candidate),
                origin.distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude))
            )
        }
        var seenNames = Set<String>()
        return (existing + mapped)
            .sorted { $0.1 < $1.1 }
            .compactMap { choice, _ in
                let key = choice.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return seenNames.insert(key).inserted ? choice : nil
            }
    }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var manualChoice: PlaceChoice { .init(source: .manual(trimmedQuery), id: "manual-\(trimmedQuery)", name: trimmedQuery, subtitle: "New restaurant · details can be added later", category: DiningCategory.suggested(for: trimmedQuery)) }
    private func choice(for candidate: PlaceCandidate) -> PlaceChoice {
        .init(source: .map(candidate), id: "map-\(candidate.id)", name: candidate.name, subtitle: candidate.address ?? candidate.suggestedCategory.shortTitle, category: candidate.suggestedCategory)
    }
    private func select(_ choice: PlaceChoice) {
        if self.choice?.id != choice.id {
            selectedReaction = nil
            detailsExpanded = false
        }
        self.choice = choice
        stage = .reaction
        Haptics.selection()
    }

    private func save(_ reaction: Reaction) {
        guard let choice else { return }
        if let location = existingLocation(for: choice),
           let personID = store.currentPerson?.id,
           let existing = store.existingOuting(at: location, near: visitDate, for: personID),
           existing.rating(for: personID) == nil {
            duplicateReaction = reaction
            duplicateOuting = existing
            return
        }
        saveNewVisit(reaction)
    }

    private func existingLocation(for choice: PlaceChoice) -> RestaurantLocation? {
        switch choice.source {
        case .existing(let location):
            return location
        case .map(let candidate):
            return store.existingLocation(
                sourceIdentifier: candidate.id,
                name: candidate.name,
                address: candidate.address
            )
        case .manual(let name):
            return store.existingLocation(name: name)
        }
    }

    private func saveNewVisit(_ reaction: Reaction) {
        guard let choice else { return }
        guard let personID = store.resolveLoggingPersonID() else {
            saveError = AppStore.missingLoggingIdentityMessage
            store.reportError(AppStore.missingLoggingIdentityMessage)
            return
        }
        saveError = nil
        let existing = existingLocation(for: choice)
        savedReaction = reaction
        capturePriorEvidence(for: existing, personID: personID)
        let (location, visit) = store.performBatch { () -> (RestaurantLocation, VisitEntity) in
            let location: RestaurantLocation
            switch choice.source {
            case .existing(let value): location = value
            case .map(let candidate):
                location = store.createLocation(
                    name: candidate.name, category: candidate.suggestedCategory, address: candidate.address, city: candidate.city,
                    coordinate: (candidate.latitude, candidate.longitude), phone: candidate.phone, url: candidate.url,
                    sourceIdentifier: candidate.id, cuisines: candidate.cuisines
                )
            case .manual(let name):
                location = store.createLocation(name: name, category: DiningCategory.suggested(for: name))
            }
            let visitCoordinate = mealPhoto?.coordinate.map { ($0.latitude, $0.longitude) }
                ?? locationService.currentVisitCoordinate(near: location.coordinate)
            let visit = store.logVisit(
                at: location,
                reaction: reaction,
                personID: personID,
                date: visitDate,
                dateKnowledge: visitDateKnowledge,
                companionIDs: store.circleMembers.filter { taggedMemberIDs.contains($0.id) }.map(\.id),
                coordinate: visitCoordinate
            )
            if let mealPhoto {
                store.addPhoto(
                    fullData: mealPhoto.fullData,
                    thumbnailData: mealPhoto.thumbnailData,
                    to: visit,
                    createdAt: mealPhoto.date,
                    captureDate: mealPhoto.captureDate
                )
            }
            return (location, visit)
        }
        savedVisit = visit
        savedScore = store.score(for: location)
        prepareQuickQuestions(for: location, score: savedScore)
        stage = .payoff
        Haptics.success()
    }

    private func join(_ outing: VisitEntity) {
        guard outing.isAlive, let reaction = duplicateReaction, let personID = store.currentPerson?.id,
              let location = outing.location else { return }
        savedReaction = reaction
        capturePriorEvidence(for: location, personID: personID)
        store.performBatch {
            _ = store.addRating(to: outing, personID: personID, reaction: reaction)
            if let mealPhoto {
                store.addPhoto(
                    fullData: mealPhoto.fullData,
                    thumbnailData: mealPhoto.thumbnailData,
                    to: outing,
                    personID: personID,
                    createdAt: mealPhoto.date,
                    captureDate: mealPhoto.captureDate
                )
            }
        }
        savedVisit = outing
        savedScore = store.score(for: location, personID: personID)
        prepareQuickQuestions(for: location, score: savedScore)
        clearDuplicateChoice()
        stage = .payoff
        Haptics.success()
    }

    private func capturePriorEvidence(for location: RestaurantLocation?, personID: UUID?) {
        guard let location else {
            oldRank = nil
            scoreBeforeSave = nil
            priorRatedVisitCount = 0
            priorReaction = nil
            return
        }
        let before = store.score(for: location, personID: personID)
        oldRank = before?.categoryRank
        scoreBeforeSave = before?.score
        priorRatedVisitCount = before?.ratedVisitCount ?? 0
        guard let personID else {
            priorReaction = nil
            return
        }
        priorReaction = location.visitArray
            .compactMap { visit -> (date: Date, reaction: Reaction)? in
                guard let rating = visit.rating(for: personID) else { return nil }
                return (visit.date, rating.reaction)
            }
            .max { $0.date < $1.date }?
            .reaction
    }

    private func prepareQuickQuestions(for location: RestaurantLocation, score: LocationScore?) {
        guard let score else {
            quickQuestions = []
            return
        }
        quickQuestions = store.ranked()
            .filter { $0.id != location.id && $0.location.category == location.category }
            .sorted { abs($0.score - score.score) < abs($1.score - score.score) }
            .prefix(3)
            .map { ComparisonQuestion(a: location, b: $0.location) }
    }

    private func clearDuplicateChoice() {
        duplicateOuting = nil
        duplicateReaction = nil
    }

    private func loadMealPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        let requestID = UUID()
        photoRequestID = requestID
        isReadingPhoto = true
        photoError = nil
        photoMapResults = []

        guard let photo = await ImageSanitizer.processSelected(
            [item],
            fallbackDate: .now,
            maxConcurrent: 1
        ).first else {
            guard photoRequestID == requestID else { return }
            mealPhoto = nil
            selectedPhotoItem = nil
            isReadingPhoto = false
            photoError = "That photo could not be read. Try another one."
            return
        }
        guard photoRequestID == requestID, !Task.isCancelled else { return }
        mealPhoto = photo
        selectedPhotoItem = nil
        visitDate = MealPhotoDraftPolicy.visitDate(for: photo, fallback: .now)
        if photo.captureDate != nil { visitDateKnowledge = .known }

        if let coordinate = photo.coordinate {
            let results = await locationService.searchNearby(
                around: coordinate,
                radius: MealPhotoDraftPolicy.restaurantLookupRadius
            )
            guard photoRequestID == requestID, !Task.isCancelled else { return }
            photoMapResults = results
        }
        isReadingPhoto = false
        Haptics.selection()
    }

    private func clearMealPhoto() {
        photoRequestID = UUID()
        selectedPhotoItem = nil
        mealPhoto = nil
        photoMapResults = []
        isReadingPhoto = false
        photoError = nil
        visitDate = .now
        visitDateKnowledge = .known
    }

    private func recordQuick(_ outcome: ComparisonOutcome, question: ComparisonQuestion) {
        store.recordComparison(a: question.a, b: question.b, outcome: outcome)
        quickIndex += 1
        Haptics.selection()
    }

    private func refreshPayoff() {
        if let visit = savedVisit, visit.isAlive, let location = visit.location {
            savedScore = store.score(for: location)
        }
    }
}

@MainActor
private struct DraftMealPhoto: View {
    let photo: BackfillPhoto
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(BBTheme.ink.opacity(0.06))
                    .overlay { ProgressView() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected outing photo")
        .task(id: photo.id) {
            image = await PhotoImageCache.display(
                key: "meal-draft-\(photo.id.uuidString)",
                data: photo.thumbnailData ?? photo.fullData,
                maxDimension: CGFloat(BackfillImportPolicy.thumbnailMaxPixelSize)
            )
        }
    }
}

@MainActor
private struct ChangeVisitRestaurantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    let currentLocationID: UUID?
    let onSelect: (PlaceChoice) -> Void
    @State private var query = ""
    @State private var mapResults: [PlaceCandidate] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Choose the restaurant").font(BBTheme.display(34))
                        Text("Search by name or address.").foregroundStyle(.secondary)
                    }
                    searchField
                    if query.isEmpty {
                        nearbySection
                        placeSection("From your log", choices: Array(existingChoices.prefix(12)), empty: "No other saved restaurants yet.")
                    } else {
                        placeSection("Your restaurants", choices: existingChoices, empty: nil)
                        placeSection("Map results", choices: mapChoices, empty: locationService.isSearching ? "Searching…" : "No map matches yet.")
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow("Not listed?")
                            Button { choose(manualChoice) } label: {
                                Label("Create “\(query)” as a new restaurant", systemImage: "plus.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 13)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("change-visit-manual-place")
                        }
                        .editorialCard(padding: 12)
                    }
                }
                .padding(20)
                .readablePageWidth()
            }
            .editorialPage()
            .navigationTitle("Change Restaurant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            guard !ProcessInfo.processInfo.arguments.contains("-resetForUITests") else { return }
            requestNearbyIfAlreadyAuthorized()
        }
        .task(id: query) {
            guard !query.isEmpty else { mapResults = []; return }
            guard !ProcessInfo.processInfo.arguments.contains("-resetForUITests") else {
                mapResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            mapResults = await locationService.search(query)
        }
    }

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Restaurant or address", text: $query)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(BBTheme.ink.opacity(0.055))
        .overlay(Rectangle().stroke(BBTheme.hairline))
        .accessibilityIdentifier("change-visit-restaurant-search")
    }

    private func placeSection(_ title: String, choices: [PlaceChoice], empty: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            if choices.isEmpty, let empty {
                Text(empty).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(choices) { choice in
                Button { choose(choice) } label: {
                    HStack(spacing: 13) {
                        Image(systemName: choice.category.symbol).foregroundStyle(BBTheme.oxblood).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.name).font(.headline).foregroundStyle(BBTheme.ink)
                            Text(choice.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var nearbySection: some View {
        if locationService.authorization == .notDetermined {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Nearby restaurants")
                Text("Your location is only used while you pick a restaurant. You can always search instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    locationService.requestNearby()
                } label: {
                    Label("Show nearby restaurants", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("change-visit-show-nearby")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .editorialCard(padding: 14)
        } else {
            placeSection("Nearby now", choices: nearbyChoices, empty: nearbyEmptyMessage)
        }
    }

    private func requestNearbyIfAlreadyAuthorized() {
        switch locationService.authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            locationService.requestNearby()
        default:
            break
        }
    }

    private var existingChoices: [PlaceChoice] {
        store.locations
            .filter { !$0.isClosed && $0.id != currentLocationID && $0.matchesPlaceQuery(query) }
            .map(\.placeChoice)
    }

    private var nearbyChoices: [PlaceChoice] { locationService.nearby.map(choice(for:)) }
    private var mapChoices: [PlaceChoice] { mapResults.map(choice(for:)) }
    private var manualChoice: PlaceChoice {
        .init(source: .manual(query), id: "manual-\(query)", name: query, subtitle: "New restaurant · details can be added later", category: DiningCategory.suggested(for: query))
    }

    private var nearbyEmptyMessage: String {
        if let errorMessage = locationService.errorMessage { return errorMessage }
        return switch locationService.authorization {
        case .denied, .restricted: "Location is off. You can still search."
        case .notDetermined: "Tap Show nearby restaurants to use your location."
        default: locationService.isSearching || locationService.usableCurrentLocation == nil ? "Looking around…" : "No nearby matches. Search below."
        }
    }

    private func choice(for candidate: PlaceCandidate) -> PlaceChoice {
        .init(source: .map(candidate), id: "map-\(candidate.id)", name: candidate.name, subtitle: candidate.address ?? candidate.suggestedCategory.shortTitle, category: candidate.suggestedCategory)
    }

    private func choose(_ choice: PlaceChoice) {
        onSelect(choice)
        Haptics.selection()
        dismiss()
    }
}

private struct DishDraft: Identifiable {
    let id = UUID()
    var name = ""
    var role: DishRole = .entree
    var reaction: Reaction = .liked
    var wouldOrderAgain = true
}

@MainActor
struct AddMoreVisitView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    private let personID: UUID?
    private let startsWithDetails: Bool
    @State private var reaction: Reaction?
    @State private var visitType: VisitType?
    @State private var visitDate: Date
    @State private var visitDateKnowledge: VisitDateKnowledge
    @State private var priceBand: Int
    @State private var occasion: Occasion?
    @State private var service: Reaction?
    @State private var atmosphere: Reaction?
    @State private var value: Reaction?
    @State private var wouldOrderAgain: Bool?
    @State private var hazy: Bool
    @State private var memory: String
    @State private var memoryExpanded: Bool
    @State private var companions: Set<UUID>
    @State private var newCompanion = ""
    @State private var dishes: [DishDraft] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isSaving = false
    @State private var restaurantChoice: PlaceChoice?
    @State private var isChangingRestaurant = false
    @State private var isConfirmingDiscard = false

    init(visit: VisitEntity, personID: UUID?, startsWithDetails: Bool = false) {
        self.visit = visit
        self.personID = personID
        self.startsWithDetails = startsWithDetails
        guard visit.isAlive else {
            _reaction = State(initialValue: nil)
            _visitType = State(initialValue: nil)
            _visitDate = State(initialValue: .now)
            _visitDateKnowledge = State(initialValue: .unknown)
            _priceBand = State(initialValue: 0)
            _occasion = State(initialValue: nil)
            _service = State(initialValue: nil)
            _atmosphere = State(initialValue: nil)
            _value = State(initialValue: nil)
            _wouldOrderAgain = State(initialValue: nil)
            _hazy = State(initialValue: false)
            _memory = State(initialValue: "")
            _memoryExpanded = State(initialValue: false)
            _companions = State(initialValue: [])
            _restaurantChoice = State(initialValue: nil)
            return
        }
        let rating = personID.flatMap(visit.rating(for:))
        _reaction = State(initialValue: rating?.reaction)
        _visitType = State(initialValue: visit.visitType)
        _visitDate = State(initialValue: visit.date)
        _visitDateKnowledge = State(initialValue: visit.dateKnowledge)
        _priceBand = State(initialValue: Int(visit.priceBand))
        _occasion = State(initialValue: visit.occasion)
        _service = State(initialValue: rating?.service)
        _atmosphere = State(initialValue: rating?.atmosphere)
        _value = State(initialValue: rating?.value)
        _wouldOrderAgain = State(initialValue: rating?.hasWouldOrderAgain == true ? rating?.wouldOrderAgain : nil)
        _hazy = State(initialValue: rating?.hazyMemory ?? false)
        let participantMemory = personID.flatMap { visit.participant(for: $0)?.memory }
        let initialMemory = participantMemory ?? (personID == visit.createdByID ? visit.memory : nil)
        _memory = State(initialValue: initialMemory ?? "")
        _memoryExpanded = State(initialValue: initialMemory?.isEmpty == false)
        _companions = State(initialValue: Set(visit.companionIDs))
        _restaurantChoice = State(initialValue: visit.location?.placeChoice)
    }

    var body: some View {
        Group {
            if visit.isAlive {
                editorContent
            } else {
                ContentUnavailableView("Outing unavailable", systemImage: "fork.knife.circle")
                    .task {
                        await Task.yield()
                        dismiss()
                    }
            }
        }
    }

    private var editorContent: some View {
        NavigationStack {
            Form {
                if startsWithDetails {
                    dishSection
                    photoSection
                    particularsSection
                    memorySection
                    if canEditOuting { companySection }
                    if canEditOuting { outingSection }
                    verdictSection
                    if canEditOuting { restaurantSection }
                } else {
                    if canEditOuting { restaurantSection }
                    verdictSection
                    if canEditOuting { outingSection }
                    dishSection
                    particularsSection
                    if canEditOuting { companySection }
                    photoSection
                    memorySection
                }
            }
            .editorialForm()
            .navigationTitle(startsWithDetails ? "Add Outing Details" : (canEditOuting ? "Edit Outing" : "Your Diner Entry"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } }
                ToolbarItem(placement: .confirmationAction) { Button(isSaving ? "Saving…" : "Save") { Task { await save() } }.disabled(isSaving) }
            }
        }
        .sheet(isPresented: $isChangingRestaurant) {
            ChangeVisitRestaurantView(currentLocationID: selectedExistingLocation?.id ?? visit.location?.id) { choice in
                restaurantChoice = choice
            }
        }
        .editorialPrompt(isPresented: $isConfirmingDiscard) {
            EditorialPrompt.destructive(
                "Discard unsaved changes?",
                message: "Anything you typed or selected here will be lost.",
                actionTitle: "Discard changes",
                cancelTitle: "Keep Editing"
            ) {
                dismiss()
            }
        }
    }

    private var outingSection: some View {
        Section {
            Toggle("Date unknown", isOn: Binding(
                get: { visitDateKnowledge == .unknown },
                set: { visitDateKnowledge = $0 ? .unknown : .known }
            ))
            if visitDateKnowledge == .known {
                DatePicker("Outing date and time", selection: $visitDate, displayedComponents: [.date, .hourAndMinute])
            }
            detailPicker("Outing type", selection: $visitType, values: VisitType.allCases)
            pricePicker
            detailPicker("Occasion", selection: $occasion, values: Occasion.allCases)
        } header: {
            Eyebrow("Details")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var restaurantSection: some View {
        Section {
            Button { isChangingRestaurant = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: restaurantChoice?.category.symbol ?? "fork.knife")
                        .foregroundStyle(BBTheme.oxblood)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(restaurantChoice?.name ?? "Choose a restaurant").font(.headline).foregroundStyle(BBTheme.ink)
                        if let subtitle = restaurantChoice?.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Text("Change").font(.callout.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("change-visit-restaurant")
        } header: {
            Eyebrow("Restaurant")
        } footer: {
            Text("Reactions, dishes, photos, and notes move with the outing.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var canEditOuting: Bool {
        visit.isAlive && store.canEditOuting(visit, personID: personID)
    }

    private var hasUnsavedChanges: Bool {
        guard visit.isAlive else { return false }
        let rating = personID.flatMap(visit.rating(for:))
        let storedWouldOrderAgain = rating?.hasWouldOrderAgain == true ? rating?.wouldOrderAgain : nil
        let participantMemory = personID.flatMap { visit.participant(for: $0)?.memory }
        let storedMemory = participantMemory ?? (personID == visit.createdByID ? visit.memory : nil) ?? ""
        return reaction != rating?.reaction ||
            visitType != visit.visitType ||
            abs(visitDate.timeIntervalSince(visit.date)) > 0.5 ||
            visitDateKnowledge != visit.dateKnowledge ||
            priceBand != Int(visit.priceBand) ||
            occasion != visit.occasion ||
            service != rating?.service ||
            atmosphere != rating?.atmosphere ||
            value != rating?.value ||
            wouldOrderAgain != storedWouldOrderAgain ||
            hazy != (rating?.hazyMemory ?? false) ||
            memory != storedMemory ||
            companions != Set(visit.companionIDs) ||
            !newCompanion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !dishes.isEmpty ||
            !photoItems.isEmpty ||
            restaurantChoice?.id != visit.location?.placeChoice.id
    }

    private func cancel() {
        guard visit.isAlive else {
            dismiss()
            return
        }
        if hasUnsavedChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private var verdictSection: some View {
        Section {
            ReactionPicker(selected: reaction) { reaction = $0 }
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                .listRowBackground(BBTheme.surface)
            Toggle("Hazy memory · counts less", isOn: $hazy)
        } header: { Eyebrow("Your reaction") } footer: {
            if reaction == nil { Text("You can leave this blank. An outing without a reaction still shows in history.") }
        }
        .listRowBackground(BBTheme.surface)
    }

    private var dishSection: some View {
        Section {
            ForEach(myDishEntries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.dish?.name ?? "Dish").font(.headline)
                        Text(entry.dish?.role.rawValue ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: entry.reaction.symbol).foregroundStyle(BBTheme.oxblood)
                        .accessibilityLabel(entry.reaction.title)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { store.deleteDishEntry(entry) } label: { Label("Remove", systemImage: "trash") }
                }
            }
            ForEach($dishes) { $dish in
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Dish name", text: $dish.name).font(.headline)
                    let suggestions = dishSuggestions(for: dish.name)
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestions) { known in
                                    Button {
                                        dish.name = known.name
                                        dish.role = known.role
                                    } label: {
                                        Label(known.name, systemImage: "clock.arrow.circlepath")
                                            .font(.caption.weight(.semibold)).lineLimit(1)
                                            .padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(BBTheme.ink.opacity(0.06), in: Capsule())
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    Picker("Role", selection: $dish.role) { ForEach(DishRole.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Reaction", selection: $dish.reaction) { ForEach(Reaction.allCases) { Text($0.compactTitle).tag($0) } }
                    Toggle("Would order again", isOn: $dish.wouldOrderAgain)
                }.padding(.vertical, 6)
            }
            Button { dishes.append(.init()) } label: { Label("Add a dish", systemImage: "plus") }
        } header: {
            Eyebrow("Dishes")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var particularsSection: some View {
        Section {
            optionalReactionPicker("Service", selection: $service)
            optionalReactionPicker("Atmosphere", selection: $atmosphere)
            optionalReactionPicker("Value", selection: $value)
            Picker("Would eat here again", selection: $wouldOrderAgain) {
                Text("Not set").tag(Bool?.none); Text("Yes").tag(Bool?.some(true)); Text("No").tag(Bool?.some(false))
            }
        } header: { Eyebrow("Optional details") } footer: {
            if reaction == nil { Text("Pick an overall reaction first.") }
        }
        .listRowBackground(BBTheme.surface)
    }

    private var companySection: some View {
        Section {
            ForEach(store.circleMembers.filter { $0.id != visit.createdByID }) { person in
                companionRow(person)
            }
            ForEach(store.namedCompanions.filter { $0.id != visit.createdByID }) { person in
                companionRow(person, detail: "Guest")
            }
            ForEach(store.people.filter {
                $0.isArchived && !$0.isCircleMember && visit.companionIDs.contains($0.id)
            }) { person in
                companionRow(person, detail: "Added before")
            }
            HStack {
                TextField("Add someone else", text: $newCompanion)
                Button("Add") {
                    if let person = store.addNamedCompanion(name: newCompanion) { companions.insert(person.id) }
                    newCompanion = ""
                }
                .disabled(newCompanion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Eyebrow("At the table")
        } footer: {
            Text("People in your circle will see this outing and can add their own reaction. Everyone else is just saved as a name.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private func companionRow(_ person: PersonEntity, detail: String? = nil) -> some View {
        Button {
            if companions.contains(person.id) { companions.remove(person.id) }
            else { companions.insert(person.id) }
        } label: {
            HStack {
                Text(person.name).foregroundStyle(BBTheme.ink)
                if let detail { Text("· \(detail)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if companions.contains(person.id) {
                    Image(systemName: "checkmark").foregroundStyle(BBTheme.oxblood)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var photoSection: some View {
        let photos = visit.photoArray
        return Section {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(photos) { photo in
                            VStack(spacing: 3) {
                                PhotoImage(photo: photo).frame(width: 64, height: 64).clipped()
                                Text(photoContributorName(photo))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contextMenu {
                                if photo.isAlive, store.canEditPhoto(photo, personID: personID) {
                                    Button("Remove my photo", systemImage: "trash", role: .destructive) {
                                        if photo.isAlive {
                                            store.deletePhoto(photo, personID: personID)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let pendingCount = photoItems.count
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: 12,
                matching: .images,
                preferredItemEncoding: .current
            ) {
                Label(pendingCount == 0 ? "Choose photos" : "\(pendingCount) selected", systemImage: "photo.on.rectangle")
            }
        } header: {
            Eyebrow("Photos")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var memorySection: some View {
        Section {
            DisclosureGroup(isExpanded: $memoryExpanded) {
                TextField("What do you want to remember?", text: $memory, axis: .vertical).lineLimit(3...8)
            } label: {
                Label(memory.isEmpty ? "Add a memory" : "Memory", systemImage: "text.quote")
            }
        } header: {
            Eyebrow("Memory")
        } footer: {
            Text("Just for you. Searchable, and it never affects the score.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private func photoContributorName(_ photo: PhotoEntity) -> String {
        guard let contributorID = photo.personID ?? photo.visit?.createdByID else { return "Diner" }
        if contributorID == personID { return "You" }
        return store.person(id: contributorID)?.name ?? "Diner"
    }

    private var myDishEntries: [DishEntryEntity] {
        guard visit.isAlive else { return [] }
        return visit.dishEntryArray.filter { $0.personID == personID }.sorted { $0.createdAt < $1.createdAt }
    }

    private func dishSuggestions(for text: String) -> [DishEntity] {
        guard let location = selectedExistingLocation else { return [] }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(dishes.map { $0.name.lowercased() } + myDishEntries.compactMap { $0.dish?.name.lowercased() })
        return Array(location.dishArray.filter { dish in
            !taken.contains(dish.name.lowercased()) &&
            dish.name.lowercased() != typed.lowercased() &&
            (typed.isEmpty || dish.name.localizedCaseInsensitiveContains(typed))
        }.prefix(4))
    }

    private var selectedExistingLocation: RestaurantLocation? {
        guard visit.isAlive else { return nil }
        guard let restaurantChoice else { return visit.location }
        if case .existing(let location) = restaurantChoice.source { return location }
        return nil
    }

    private var pricePicker: some View {
        Picker("Price", selection: $priceBand) {
            Text("Not set").tag(0)
            ForEach(1...4, id: \.self) { Text(String(repeating: "$", count: $0)).tag($0) }
        }
    }
    private func detailPicker<T: Hashable & Identifiable & RawRepresentable>(_ title: String, selection: Binding<T?>, values: [T]) -> some View where T.RawValue == String {
        Picker(title, selection: selection) { Text("Not set").tag(T?.none); ForEach(values) { Text($0.rawValue).tag(T?.some($0)) } }
    }
    private func optionalReactionPicker(_ title: String, selection: Binding<Reaction?>) -> some View {
        Picker(title, selection: selection) { Text("Not set").tag(Reaction?.none); ForEach(Reaction.allCases) { Text($0.compactTitle).tag(Reaction?.some($0)) } }
    }

    private func save() async {
        guard visit.isAlive else {
            dismiss()
            return
        }
        isSaving = true
        defer { isSaving = false }
        let fallbackDate = visit.date
        let sanitizedPhotos = await ImageSanitizer.processSelected(photoItems, fallbackDate: fallbackDate)
        guard !Task.isCancelled, visit.isAlive else {
            dismiss()
            return
        }

        store.performBatch {
            guard visit.isAlive else { return }
            if canEditOuting, let restaurantChoice {
                let selectedLocation: RestaurantLocation
                switch restaurantChoice.source {
                case .existing(let location):
                    selectedLocation = location
                case .map(let candidate):
                    selectedLocation = store.createLocation(
                        name: candidate.name, category: candidate.suggestedCategory, address: candidate.address, city: candidate.city,
                        coordinate: (candidate.latitude, candidate.longitude), phone: candidate.phone, url: candidate.url,
                        sourceIdentifier: candidate.id, cuisines: candidate.cuisines
                    )
                case .manual(let name):
                    selectedLocation = store.createLocation(name: name, category: DiningCategory.suggested(for: name))
                }
                store.changeLocation(of: visit, to: selectedLocation, editorID: personID)
            }
            if canEditOuting {
                store.updateVisitDate(
                    visit,
                    date: visitDateKnowledge == .known ? visitDate : nil,
                    editorID: personID
                )
                store.updateVisit(
                    visit, type: visitType, priceBand: priceBand, occasion: occasion,
                    memory: memory, companions: Array(companions), editorID: personID
                )
            } else {
                store.updateMemory(memory, for: visit, personID: personID)
            }
            if let personID {
                if let reaction {
                    let rating = store.addRating(to: visit, personID: personID, reaction: reaction, hazy: hazy)
                    store.updateRating(rating, service: service, atmosphere: atmosphere, value: value, wouldOrderAgain: wouldOrderAgain, hazy: hazy)
                }
                for dish in dishes {
                    _ = store.addDish(name: dish.name, role: dish.role, reaction: dish.reaction, wouldOrderAgain: dish.wouldOrderAgain, to: visit, personID: personID)
                }
            }
            store.updateVisitDateFromPhotoMetadata(visit, photos: sanitizedPhotos)
            for photo in sanitizedPhotos {
                store.addPhoto(
                    fullData: photo.fullData,
                    thumbnailData: photo.thumbnailData,
                    to: visit,
                    personID: personID,
                    createdAt: photo.date,
                    captureDate: photo.captureDate
                )
            }
        }
        Haptics.success(); dismiss()
    }
}
