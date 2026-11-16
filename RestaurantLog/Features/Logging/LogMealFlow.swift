import CoreLocation
import PhotosUI
import SwiftUI
import UIKit

struct PlaceChoice: Identifiable {
    enum Source { case existing(RestaurantLocation), map(PlaceCandidate), manual(String) }
    let source: Source
    let id: String
    let name: String
    let subtitle: String
    let category: DiningCategory
}

struct PlaceSearchKey: Hashable {
    let query: String
    let latitude: Double?
    let longitude: Double?
}

extension RestaurantLocation {
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
struct DraftMealPhoto: View {
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
            if visit.isAlive, canEditDinerEntry {
                editorContent
            } else {
                ContentUnavailableView(
                    visit.isAlive ? "Outing is read-only" : "Outing unavailable",
                    systemImage: "fork.knife.circle"
                )
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
                    .environment(
                        \.calendar,
                        DiningDateContext.calendar(offsetSeconds: visit.dateTimeZoneOffsetSeconds?.intValue)
                    )
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

    private var canEditDinerEntry: Bool {
        visit.isAlive && store.canEditDinerEntry(visit, personID: personID)
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
        guard visit.isAlive, canEditDinerEntry else {
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
                    dateTimeZoneOffsetSeconds: visit.dateTimeZoneOffsetSeconds?.intValue,
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
                    if let rating = store.addRating(to: visit, personID: personID, reaction: reaction, hazy: hazy) {
                        store.updateRating(
                            rating,
                            service: service,
                            atmosphere: atmosphere,
                            value: value,
                            wouldOrderAgain: wouldOrderAgain,
                            hazy: hazy,
                            personID: personID
                        )
                    }
                }
                for dish in dishes {
                    _ = store.addDish(name: dish.name, role: dish.role, reaction: dish.reaction, wouldOrderAgain: dish.wouldOrderAgain, to: visit, personID: personID)
                }
            }
            store.updateVisitDateFromPhotoMetadata(visit, photos: sanitizedPhotos, editorID: personID)
            for photo in sanitizedPhotos {
                store.addPhoto(
                    fullData: photo.fullData,
                    thumbnailData: photo.thumbnailData,
                    to: visit,
                    personID: personID,
                    createdAt: photo.date,
                    captureDate: photo.captureDate,
                    captureTimeZoneOffsetSeconds: photo.captureTimeZoneOffsetSeconds
                )
            }
        }
        Haptics.success(); dismiss()
    }
}
