import SwiftUI

private struct SharedDishDraft: Identifiable {
    let id = UUID()
    var name = ""
    var role: DishRole = .entree
    var reaction: Reaction = .liked
    var wouldOrderAgain = false
}

private struct OtherDinerDish: Identifiable {
    let dish: DishEntity
    let dinerNames: [String]
    var id: UUID { dish.id }
}

@MainActor
struct SharedVisitRatingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    @State private var reaction: Reaction?
    @State private var dishDrafts: [SharedDishDraft] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CategoryArtwork(category: visit.location?.category ?? .fullService, height: 150)
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Shared outing · \(visit.dateKnowledge == .known ? visit.date.formatted(date: .abbreviated, time: .omitted) : "Date unknown")")
                        Text(visit.location?.name ?? "Shared outing").font(BBTheme.display(34))
                        Text("\(authorName) included you in this outing. Add only your own reaction and the dishes you personally tried.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        EditorialSectionHeader("Your reaction", eyebrow: "Independent opinion")
                        ReactionPicker(selected: reaction) { reaction = $0 }
                    }
                    yourDishes
                    if !otherDinerDishes.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            EditorialSectionHeader("Others at the table", eyebrow: "Add only if you tried it too")
                            ForEach(otherDinerDishes) { option in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.dish.name).font(.headline)
                                        Text("\(option.dinerNames.joined(separator: ", ")) ordered this")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("I Tried This") { add(option.dish) }
                                        .font(.callout.weight(.semibold))
                                        .disabled(hasDraft(named: option.dish.name))
                                }
                                .editorialCard(padding: 14)
                            }
                        }
                    }
                    responseActions
                }.padding(18).readablePageWidth()
            }.editorialPage().navigationTitle("Add Your Entry").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(reaction == nil && !hasValidDishDraft) } }
        }
    }

    private var yourDishes: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("What did you eat?", eyebrow: "Optional · your dishes only")
            ForEach($dishDrafts) { $dish in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Dish name", text: $dish.name).font(.headline)
                        Button("Remove", systemImage: "xmark.circle.fill") {
                            dishDrafts.removeAll { $0.id == dish.id }
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    }
                    Picker("Role", selection: $dish.role) {
                        ForEach(DishRole.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Your reaction", selection: $dish.reaction) {
                        ForEach(Reaction.allCases) { Text($0.compactTitle).tag($0) }
                    }
                    Toggle("Would order again", isOn: $dish.wouldOrderAgain)
                }
                .editorialCard()
            }
            Button { dishDrafts.append(.init()) } label: {
                Label("Add My Dish", systemImage: "plus.circle.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var responseActions: some View {
        VStack(spacing: 10) {
            Button("I Was There, No Entry") {
                store.declineRating(for: visit)
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("I Wasn’t There", role: .destructive) {
                store.markNotPresent(for: visit)
                dismiss()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var authorName: String {
        store.person(id: visit.createdByID)?.name ?? "Someone in your circle"
    }

    private var otherDinerDishes: [OtherDinerDish] {
        guard let personID = store.currentPerson?.id else { return [] }
        let entries = visit.dishEntryArray.filter { $0.personID != personID }
        let grouped = Dictionary(grouping: entries) { $0.dish?.id }
        return grouped.values.compactMap { values in
            guard let dish = values.compactMap(\.dish).first else { return nil }
            let names = Set(values.compactMap { store.person(id: $0.personID)?.name }).sorted()
            return OtherDinerDish(dish: dish, dinerNames: names.isEmpty ? ["Another diner"] : names)
        }.sorted { $0.dish.name.localizedCaseInsensitiveCompare($1.dish.name) == .orderedAscending }
    }

    private func hasDraft(named name: String) -> Bool {
        dishDrafts.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private var hasValidDishDraft: Bool {
        dishDrafts.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func add(_ dish: DishEntity) {
        guard !hasDraft(named: dish.name) else { return }
        dishDrafts.append(.init(name: dish.name, role: dish.role))
    }

    private func save() {
        guard let personID = store.currentPerson?.id else { return }
        if let reaction { _ = store.addRating(to: visit, personID: personID, reaction: reaction) }
        for dish in dishDrafts {
            _ = store.addDish(
                name: dish.name, role: dish.role, reaction: dish.reaction,
                wouldOrderAgain: dish.wouldOrderAgain, to: visit, personID: personID
            )
        }
        Haptics.success(); dismiss()
    }
}

@MainActor
struct CircleSharingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @State private var invitation: CircleInvitation?
    @State private var isWorking = false
    @State private var newPerson = ""

    private var circleIsSynced: Bool {
        guard let circle = store.activeCircle else { return false }
        return sync.isSyncing(circleID: circle.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    memberCard
                    if !sync.isConfigured {
                        unavailableCard
                    } else if !sync.isSignedIn {
                        signInCard
                    } else if circleIsSynced {
                        syncedCard
                        invitationCard
                    } else {
                        enableCard
                    }
                    if let message = sync.lastError {
                        Text(message).font(.caption).foregroundStyle(BBTheme.oxblood)
                    }
                    Text("Outings, ratings and photos are encrypted on this iPhone before they are uploaded. The key stays on the devices in your circle and travels only inside an invitation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .readablePageWidth()
            }
            .editorialPage()
            .navigationTitle("Your Circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Private circle")
            Text("Share with your circle").font(BBTheme.display(36))
            Text("Invite up to six people. Everyone sees shared outings, while each diner\u{2019}s entry and rankings stay personal.")
                .foregroundStyle(.secondary)
        }
    }

    private var memberCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.circleMembers) { person in
                Label(
                    person.name + (person.id == store.currentPerson?.id ? " (this device)" : ""),
                    systemImage: "person.crop.circle.fill"
                )
            }
            if store.circleMembers.count < 6 {
                HStack {
                    TextField("Circle member", text: $newPerson)
                    Button("Add") {
                        _ = store.addCircleMember(name: newPerson)
                        newPerson = ""
                    }
                    .disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .editorialCard()
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Syncing")
            Text("Not available in this build").font(.headline)
            Text("This copy of the app has no sync service configured, so the log stays on this iPhone. Backups in Settings still move it between devices.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .editorialCard()
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Syncing")
            Text("Sign in to sync").font(.headline)
            Text("Signing in tells the sync service which member a device belongs to. It never receives your dining records in readable form.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                run { await sync.signInWithApple() }
            } label: {
                Label("Sign in with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking)
        }
        .editorialCard()
    }

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Syncing")
            Text("Turn on syncing for this circle").font(.headline)
            Text("A key is created on this iPhone and stored in its Keychain. Everything uploaded from here on is encrypted with it first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                guard let circle = store.activeCircle else { return }
                run { await sync.enableSync(circleID: circle.id, circleName: circle.name) }
            } label: {
                if isWorking {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Turn On Syncing", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking || store.activeCircle == nil)
        }
        .editorialCard()
    }

    private var syncedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Syncing")
            LabeledContent("Status", value: sync.status.description)
            if let outcome = sync.lastOutcome, outcome.conflicts > 0 {
                Text("This device\u{2019}s version was kept for \(outcome.conflicts) record(s) edited in two places.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Sync Now") {
                guard let circle = store.activeCircle else { return }
                run { await sync.sync(circleID: circle.id) }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isWorking || sync.status.isBusy)
        }
        .editorialCard()
    }

    private var invitationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Invitations")
            Text("Invite someone").font(.headline)
            Text("An invitation carries the circle key, so send it the way you would send a house key \u{2014} directly to the person, in a conversation you trust. It works once and expires in seven days.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let invitation, let url = invitation.url {
                ShareLink(item: url) {
                    Label("Send Invitation", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("Anyone who opens this link joins the circle. Create a new one if it goes astray.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    guard let circle = store.activeCircle else { return }
                    run { invitation = await sync.makeInvitation(circleID: circle.id, circleName: circle.name) }
                } label: {
                    if isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Create Invitation", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking)
            }
        }
        .editorialCard()
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}

/// Presented when an invitation link is opened on this device.
@MainActor
struct JoinCircleView: View {
    let invitation: CircleInvitation
    let onJoined: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SyncCoordinator.self) private var sync
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("Invitation")
                        Text(invitation.circleName).font(BBTheme.display(34))
                        Text("Joining adds this iPhone to the circle and downloads its outings, dishes and photos. Your ratings and rankings stay your own.")
                            .foregroundStyle(.secondary)
                    }
                    if !sync.isSignedIn {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sign in first").font(.headline)
                            Button {
                                run { await sync.signInWithApple() }
                            } label: {
                                Label("Sign in with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(isWorking)
                        }
                        .editorialCard()
                    } else {
                        Button {
                            run {
                                if await sync.join(invitation) {
                                    onJoined()
                                    dismiss()
                                } else {
                                    error = sync.lastError
                                }
                            }
                        } label: {
                            if isWorking {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Label("Join This Circle", systemImage: "person.2.fill").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isWorking)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(BBTheme.oxblood)
                    }
                }
                .padding(22)
                .readablePageWidth()
            }
            .editorialPage()
            .navigationTitle("Join Circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } } }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}

@MainActor
struct DeviceIdentitySelectionView: View {
    @Environment(AppStore.self) private var store
    @State private var newPerson = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(BBTheme.oxblood)
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("Shared circle")
                        Text("Who are you in this circle?").font(BBTheme.display(36))
                        Text("Choose before adding ratings or visits. This selection applies only to this device and this circle.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        ForEach(store.circleMembers) { person in
                            Button {
                                store.selectCurrentPerson(person.id)
                            } label: {
                                HStack {
                                    Circle().fill(Color(hex: person.colorHex)).frame(width: 28, height: 28)
                                    Text(person.name).font(.headline)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                .padding(16)
                                .frame(minHeight: 56)
                                .background(BBTheme.ink.opacity(0.045))
                                .overlay(Rectangle().stroke(BBTheme.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if store.circleMembers.count < 6 {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow("Not listed?")
                            TextField("Your name", text: $newPerson)
                                .textInputAutocapitalization(.words)
                                .padding(12)
                                .background(BBTheme.ink.opacity(0.045))
                            Button("Add Me to This Circle") {
                                guard let person = store.addCircleMember(name: newPerson) else { return }
                                store.selectCurrentPerson(person.id)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(newPerson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .editorialCard()
                    }
                    Text("You can change this later in Settings. Rankings remain separate for each person.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
                .readablePageWidth()
            }
            .editorialPage()
            .navigationTitle(store.activeCircle?.name ?? "Your Circle")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
