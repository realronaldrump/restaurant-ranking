import PhotosUI
import SwiftUI

private struct PlaceChoice: Identifiable {
    enum Source { case existing(RestaurantLocation), map(PlaceCandidate), manual(String) }
    let source: Source
    let id: String
    let name: String
    let subtitle: String
    let category: DiningCategory
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
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @State private var stage: Stage = .place
    @State private var choice: PlaceChoice?
    @State private var query = ""
    @State private var mapResults: [PlaceCandidate] = []
    @State private var savedVisit: VisitEntity?
    @State private var savedScore: LocationScore?
    @State private var oldRank: Int?
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
                        Button(leadingButtonTitle) {
                            if stage == .place { dismiss() }
                            else if stage == .reaction { stage = .place }
                            else if stage == .quickComparisons { refreshPayoff(); stage = .payoff }
                        }
                    }
                }
                ToolbarItem(placement: .principal) { Eyebrow(stageTitle) }
            }
        }
        .interactiveDismissDisabled(stage == .payoff)
        .sheet(item: $addMoreVisit) { visit in AddMoreVisitView(visit: visit, personID: store.currentPerson?.id) }
        .task {
            guard !ProcessInfo.processInfo.arguments.contains("-resetForUITests") else { return }
            locationService.requestNearby()
        }
    }

    private var stageTitle: String {
        switch stage { case .place: "Log a Meal · 1 of 2"; case .reaction: "Log a Meal · 2 of 2"; case .payoff: "Meal saved"; case .quickComparisons: "Optional comparisons" }
    }

    private var leadingButtonTitle: String {
        switch stage { case .place: "Cancel"; case .reaction: "Back"; case .payoff: "Done"; case .quickComparisons: "Back" }
    }

    private var placePicker: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Where did you eat?").font(BBTheme.display(37))
                    Text("Nearby first. Search if the guess misses.").foregroundStyle(.secondary)
                }
                searchField
                if query.isEmpty {
                    placeSection("Nearby now", choices: nearbyChoices, empty: nearbyEmptyMessage)
                    placeSection("From your ledger", choices: Array(existingChoices.prefix(8)), empty: "Your visited places will appear here.")
                } else {
                    Button { select(manualChoice) } label: {
                        Label("Add “\(query)” as a new place", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
                    }.buttonStyle(.plain).accessibilityIdentifier("manual-place-choice")
                    placeSection("Your places", choices: existingChoices, empty: nil)
                    placeSection("Map results", choices: mapChoices, empty: locationService.isSearching ? "Searching…" : "No outside match yet.")
                }
            }.padding(20).readablePageWidth()
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
            TextField("Search restaurants and cafés", text: $query)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary).accessibilityLabel("Clear search") }
        }
        .padding(.horizontal, 14).frame(minHeight: 50).background(BBTheme.ink.opacity(0.055)).overlay(Rectangle().stroke(BBTheme.hairline))
        .accessibilityIdentifier("log-place-search")
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
            }
        }
    }

    private var reactionPicker: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let choice {
                    CategoryArtwork(category: choice.category, height: 170)
                    VStack(spacing: 6) {
                        Text(choice.name).font(BBTheme.display(34)).multilineTextAlignment(.center)
                        Text(choice.subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow("Your immediate verdict")
                        ReactionPicker(selected: nil) { reaction in save(reaction) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text("That’s enough to save the visit. Everything else is optional.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.padding(20).readablePageWidth()
        }
    }

    private var payoff: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 16)
                if let visit = savedVisit, let location = visit.location, let score = savedScore {
                    VStack(spacing: 8) {
                        Eyebrow("Current ranking")
                        Text(location.name).font(BBTheme.display(35)).multilineTextAlignment(.center)
                        ScoreMark(score: score.score, caption: "current score", size: 74, provisional: score.isProvisional)
                    }
                    .padding(.bottom, 4)
                    .scaleEffect(payoffAppeared ? 1 : 0.85)
                    .opacity(payoffAppeared ? 1 : 0)
                    rankingInsertion(score)
                    if !quickQuestions.isEmpty {
                        Button { quickIndex = 0; stage = .quickComparisons } label: {
                            Label("Place It More Precisely", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Add Dishes, Photos & Details") { addMoreVisit = visit }.buttonStyle(PrimaryButtonStyle())
                    Button("Done") { dismiss() }.font(.headline).frame(minHeight: 48)
                }
                Spacer(minLength: 20)
            }.padding(20).readablePageWidth()
        }
        .onAppear { withAnimation(.spring(duration: 0.55, bounce: 0.3)) { payoffAppeared = true } }
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
                    Button("Return to the Result") { refreshPayoff(); stage = .payoff }.buttonStyle(PrimaryButtonStyle())
                    Spacer(minLength: 12)
                }.padding(22).readablePageWidth()
            } else {
                let question = quickQuestions[quickIndex]
                VStack(spacing: 18) {
                    HStack { Eyebrow("Optional \(quickIndex + 1) of \(quickQuestions.count)"); Spacer() }
                    Spacer(minLength: 12)
                    Text("Which would you rather revisit tonight?").font(BBTheme.display(33)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    quickChoice(question.a, outcome: .a, question: question)
                    Text("OR").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                    quickChoice(question.b, outcome: .b, question: question)
                    Button("Too Close to Call") { recordQuick(.tie, question: question) }.buttonStyle(SecondaryButtonStyle())
                    Button("Skip") { quickIndex += 1 }.frame(minHeight: 44)
                    Button("Finish Now") { refreshPayoff(); stage = .payoff }.font(.callout).foregroundStyle(.secondary).frame(minHeight: 44)
                }.padding(22).padding(.bottom, 12).readablePageWidth()
            }
        }
    }

    private func quickChoice(_ location: RestaurantLocation, outcome: ComparisonOutcome, question: ComparisonQuestion) -> some View {
        Button { recordQuick(outcome, question: question) } label: {
            HStack { Image(systemName: location.category.symbol); Text(location.name).font(BBTheme.display(22)); Spacer(); if let score = store.score(for: location) { Text(score.displayScore).font(BBTheme.score(21)) } }
                .padding(18).foregroundStyle(BBTheme.paper).background(BBTheme.oxblood)
        }.buttonStyle(.pressable)
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
            HStack(spacing: 14) {
                neighbor(above, label: "Sits behind")
                Divider().frame(height: 50)
                neighbor(below, label: "Just passed")
            }
        }.ledgerCard()
    }

    private func neighbor(_ score: LocationScore?, label: String) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(score?.location.name ?? "None").font(.callout.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }

    private var nearbyEmptyMessage: String {
        switch locationService.authorization {
        case .denied, .restricted: "Location is off. You can still search."
        case .notDetermined: "Turn on location for nearby results, or search instead."
        default: locationService.isSearching || locationService.currentLocation == nil ? "Looking around…" : "No nearby matches. Search below."
        }
    }

    private var existingChoices: [PlaceChoice] {
        store.locations.filter { !$0.isClosed && $0.matchesPlaceQuery(query) }.map(\.placeChoice)
    }
    private var nearbyChoices: [PlaceChoice] { locationService.nearby.map(choice(for:)) }
    private var mapChoices: [PlaceChoice] { mapResults.map(choice(for:)) }
    private var manualChoice: PlaceChoice { .init(source: .manual(query), id: "manual-\(query)", name: query, subtitle: "New establishment · details editable later", category: DiningCategory.suggested(for: query)) }
    private func choice(for candidate: PlaceCandidate) -> PlaceChoice {
        .init(source: .map(candidate), id: "map-\(candidate.id)", name: candidate.name, subtitle: candidate.address ?? candidate.suggestedCategory.shortTitle, category: candidate.suggestedCategory)
    }
    private func select(_ choice: PlaceChoice) { self.choice = choice; stage = .reaction; Haptics.selection() }

    private func save(_ reaction: Reaction) {
        guard let choice else { return }
        let existing: RestaurantLocation? = if case .existing(let value) = choice.source { value } else { nil }
        oldRank = existing.flatMap { location in store.score(for: location)?.categoryRank }
        let currentCoordinate = locationService.currentLocation.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
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
                location = store.createLocation(name: name, category: DiningCategory.suggested(for: name), coordinate: currentCoordinate)
            }
            let visit = store.logVisit(at: location, reaction: reaction, coordinate: currentCoordinate)
            return (location, visit)
        }
        savedVisit = visit
        savedScore = store.score(for: location)
        if existing == nil, let score = savedScore {
            quickQuestions = store.ranked()
                .filter { $0.id != location.id && $0.location.category == location.category }
                .sorted { abs($0.score - score.score) < abs($1.score - score.score) }
                .prefix(3)
                .map { ComparisonQuestion(a: location, b: $0.location) }
        }
        stage = .payoff
        Haptics.success()
    }

    private func recordQuick(_ outcome: ComparisonOutcome, question: ComparisonQuestion) {
        store.recordComparison(a: question.a, b: question.b, outcome: outcome)
        quickIndex += 1
        Haptics.selection()
    }

    private func refreshPayoff() {
        if let location = savedVisit?.location { savedScore = store.score(for: location) }
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
                        Text("Choose the right place").font(BBTheme.display(34))
                        Text("Search by restaurant, address, or branch.").foregroundStyle(.secondary)
                    }
                    searchField
                    if query.isEmpty {
                        placeSection("Nearby now", choices: nearbyChoices, empty: nearbyEmptyMessage)
                        placeSection("From your ledger", choices: Array(existingChoices.prefix(12)), empty: "No other saved places yet.")
                    } else {
                        Button { choose(manualChoice) } label: {
                            Label("Add “\(query)” as a new place", systemImage: "plus.circle.fill")
                                .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("change-visit-manual-place")
                        placeSection("Your places", choices: existingChoices, empty: nil)
                        placeSection("Map results", choices: mapChoices, empty: locationService.isSearching ? "Searching…" : "No outside match yet.")
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
            locationService.requestNearby()
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
            TextField("Restaurant, address, or branch", text: $query)
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
    }

    private var existingChoices: [PlaceChoice] {
        store.locations
            .filter { !$0.isClosed && $0.id != currentLocationID && $0.matchesPlaceQuery(query) }
            .map(\.placeChoice)
    }

    private var nearbyChoices: [PlaceChoice] { locationService.nearby.map(choice(for:)) }
    private var mapChoices: [PlaceChoice] { mapResults.map(choice(for:)) }
    private var manualChoice: PlaceChoice {
        .init(source: .manual(query), id: "manual-\(query)", name: query, subtitle: "New establishment · details editable later", category: DiningCategory.suggested(for: query))
    }

    private var nearbyEmptyMessage: String {
        switch locationService.authorization {
        case .denied, .restricted: "Location is off. You can still search."
        case .notDetermined: "Turn on location for nearby results, or search instead."
        default: locationService.isSearching || locationService.currentLocation == nil ? "Looking around…" : "No nearby matches. Search below."
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
    @State private var reaction: Reaction?
    @State private var visitType: VisitType?
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

    init(visit: VisitEntity, personID: UUID?) {
        self.visit = visit
        self.personID = personID
        let rating = personID.flatMap(visit.rating(for:))
        _reaction = State(initialValue: rating?.reaction)
        _visitType = State(initialValue: visit.visitType)
        _priceBand = State(initialValue: Int(visit.priceBand))
        _occasion = State(initialValue: visit.occasion)
        _service = State(initialValue: rating?.service)
        _atmosphere = State(initialValue: rating?.atmosphere)
        _value = State(initialValue: rating?.value)
        _wouldOrderAgain = State(initialValue: rating?.hasWouldOrderAgain == true ? rating?.wouldOrderAgain : nil)
        _hazy = State(initialValue: rating?.hazyMemory ?? false)
        _memory = State(initialValue: visit.memory ?? "")
        _memoryExpanded = State(initialValue: visit.memory?.isEmpty == false)
        _companions = State(initialValue: Set(visit.companionIDs))
        _restaurantChoice = State(initialValue: visit.location?.placeChoice)
    }

    var body: some View {
        NavigationStack {
            Form {
                restaurantSection
                verdictSection
                Section { detailPicker("Visit type", selection: $visitType, values: VisitType.allCases); pricePicker; detailPicker("Occasion", selection: $occasion, values: Occasion.allCases) } header: { Text("The visit") }
                dishSection
                particularsSection
                companySection
                photoSection
                memorySection
            }
            .editorialForm()
            .navigationTitle("Add More").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(isSaving ? "Saving…" : "Save") { Task { await save() } }.disabled(isSaving) }
            }
        }
        .sheet(isPresented: $isChangingRestaurant) {
            ChangeVisitRestaurantView(currentLocationID: selectedExistingLocation?.id ?? visit.location?.id) { choice in
                restaurantChoice = choice
            }
        }
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
            Text("Restaurant")
        } footer: {
            Text("Changing the restaurant keeps this visit’s ratings, dishes, photos, and notes together.")
        }
    }

    private var verdictSection: some View {
        Section {
            ReactionPicker(selected: reaction) { reaction = $0 }
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                .listRowBackground(Color.clear)
            Toggle("Hazy memory · weight it lightly", isOn: $hazy)
        } header: { Text("Your verdict") } footer: {
            if reaction == nil { Text("A visit can stay unrated forever. Choose a reaction only when you have one.") }
        }
    }

    private var dishSection: some View {
        Section("Dishes") {
            ForEach(myDishEntries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.dish?.name ?? "Dish").font(.headline)
                        Text(entry.dish?.role.rawValue ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: entry.reaction.symbol).foregroundStyle(BBTheme.oxblood)
                        .accessibilityLabel(entry.reaction.rawValue)
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
        }
    }

    private var particularsSection: some View {
        Section {
            optionalReactionPicker("Service", selection: $service)
            optionalReactionPicker("Atmosphere", selection: $atmosphere)
            optionalReactionPicker("Value", selection: $value)
            Picker("Would order again", selection: $wouldOrderAgain) {
                Text("Not set").tag(Bool?.none); Text("Yes").tag(Bool?.some(true)); Text("No").tag(Bool?.some(false))
            }
        } header: { Text("Optional ratings") } footer: {
            if reaction == nil { Text("Choose an overall reaction before adding these ratings.") }
        }
    }

    private var companySection: some View {
        Section("Company") {
            ForEach(store.people.filter { $0.id != personID }) { person in
                Button {
                    if companions.contains(person.id) { companions.remove(person.id) } else { companions.insert(person.id) }
                } label: {
                    HStack {
                        Text(person.name).foregroundStyle(BBTheme.ink)
                        if !person.isCircleMember { Text("· companion").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if companions.contains(person.id) { Image(systemName: "checkmark").foregroundStyle(BBTheme.oxblood) }
                    }
                }
            }
            HStack {
                TextField("Add a named companion", text: $newCompanion)
                Button("Add") {
                    if let person = store.addNamedCompanion(name: newCompanion) { companions.insert(person.id) }
                    newCompanion = ""
                }
                .disabled(newCompanion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var photoSection: some View {
        Section("Photos") {
            if !visit.photoArray.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(visit.photoArray) { photo in
                            PhotoImage(photo: photo).frame(width: 64, height: 64).clipped()
                                .contextMenu { Button("Remove Photo", systemImage: "trash", role: .destructive) { store.deletePhoto(photo) } }
                        }
                    }
                }
            }
            let pendingCount = photoItems.count
            PhotosPicker(selection: $photoItems, maxSelectionCount: 12, matching: .images) {
                Label(pendingCount == 0 ? "Choose photos" : "\(pendingCount) selected to add", systemImage: "photo.on.rectangle")
            }
        }
    }

    private var memorySection: some View {
        Section {
            DisclosureGroup(isExpanded: $memoryExpanded) {
                TextField("What do you want to remember?", text: $memory, axis: .vertical).lineLimit(3...8)
            } label: {
                Label(memory.isEmpty ? "Add a Memory" : "Memory", systemImage: "text.quote")
            }
        } footer: { Text("Memories are searchable and never affect the score.") }
    }

    private var myDishEntries: [DishEntryEntity] {
        visit.dishEntryArray.filter { $0.personID == personID }.sorted { $0.createdAt < $1.createdAt }
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
        isSaving = true
        var sanitizedPhotos: [BackfillPhoto] = []
        for item in photoItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let photo = await ImageSanitizer.processOffMain(data) {
                sanitizedPhotos.append(photo)
            }
        }

        store.performBatch {
            if let restaurantChoice {
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
                store.changeLocation(of: visit, to: selectedLocation)
            }
            store.updateVisit(visit, type: visitType, priceBand: priceBand, occasion: occasion, memory: memory, companions: Array(companions))
            if let personID {
                if let reaction {
                    let rating = store.addRating(to: visit, personID: personID, reaction: reaction, hazy: hazy)
                    store.updateRating(rating, service: service, atmosphere: atmosphere, value: value, wouldOrderAgain: wouldOrderAgain, hazy: hazy)
                }
                for dish in dishes {
                    _ = store.addDish(name: dish.name, role: dish.role, reaction: dish.reaction, wouldOrderAgain: dish.wouldOrderAgain, to: visit, personID: personID)
                }
            }
            for photo in sanitizedPhotos {
                store.addPhoto(fullData: photo.fullData, thumbnailData: photo.thumbnailData, to: visit, createdAt: photo.date)
            }
        }
        Haptics.success(); isSaving = false; dismiss()
    }
}
