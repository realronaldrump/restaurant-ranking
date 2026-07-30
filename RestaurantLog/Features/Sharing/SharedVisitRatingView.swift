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
    @Environment(AppRouter.self) private var router
    @State private var invitation: CircleInvitation?
    @State private var isWorking = false
    @State private var newPerson = ""
    @State private var inviteeID: UUID?
    @State private var memberToRemove: SupabaseClient.MembershipRow?
    @State private var isConfirmingServiceDeletion = false
    @State private var isRenamingCircle = false
    @State private var circleNameDraft = ""
    @State private var circleRenameError: String?
    @State private var isCreatingCircle = false
    @State private var newCircleName = ""
    @State private var newCircleOwnerName = ""
    @State private var localCirclePendingDeletion: UUID?

    private var circleIsSynced: Bool {
        guard let circle = store.activeCircle else { return false }
        return sync.isSyncing(circleID: circle.id)
    }

    private var circleHasKey: Bool {
        guard let circle = store.activeCircle else { return false }
        return sync.hasCircleKey(circleID: circle.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    circleLibraryCard
                    memberCard
                    if !sync.isConfigured {
                        unavailableCard
                    } else if !sync.isSignedIn {
                        signInCard
                    } else if circleHasKey {
                        syncedCard
                        invitationCard
                        if currentAccountMembership != nil {
                            serviceDataCard
                        }
                    } else {
                        enableCard
                    }
                    if !circleHasKey {
                        localCircleActionsCard
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
            .task(id: circleTaskID) {
                guard let circleID = store.activeCircleID, circleHasKey, sync.isSignedIn else { return }
                await sync.refreshMembers(circleID: circleID)
                selectFirstInviteeIfNeeded()
            }
            .alert("Rename Circle", isPresented: $isRenamingCircle) {
                TextField("Circle name", text: $circleNameDraft)
                    .textInputAutocapitalization(.words)
                Button("Save") { saveCircleName() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use a short name everyone in the circle will recognize.")
            }
            .alert("Create a New Circle", isPresented: $isCreatingCircle) {
                TextField("Circle name", text: $newCircleName)
                    .textInputAutocapitalization(.words)
                TextField("Your name in this circle", text: $newCircleOwnerName)
                    .textInputAutocapitalization(.words)
                Button("Create") { createCircle() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each circle is a separate private dining log. Records and rankings never mix between circles.")
            }
            .confirmationDialog(
                "Remove this member from syncing?",
                isPresented: Binding(
                    get: { memberToRemove != nil },
                    set: { if !$0 { memberToRemove = nil } }
                ),
                presenting: memberToRemove
            ) { membership in
                Button("Remove Sync Access", role: .destructive) {
                    guard let circleID = store.activeCircleID else { return }
                    run {
                        _ = await sync.removeMember(circleID: circleID, userID: membership.userID)
                        memberToRemove = nil
                        selectFirstInviteeIfNeeded()
                    }
                }
                Button("Cancel", role: .cancel) { memberToRemove = nil }
            } message: { membership in
                Text("Their on-device log is unchanged, but this account will no longer be able to read or write the circle on the sync service. You can invite the same circle member again later.")
            }
            .confirmationDialog(
                isCurrentAccountOwner ? "Delete this circle from the sync service?" : "Leave this synced circle?",
                isPresented: $isConfirmingServiceDeletion,
                titleVisibility: .visible
            ) {
                Button(isCurrentAccountOwner ? "Delete Circle" : "Leave Circle", role: .destructive) {
                    guard let circleID = store.activeCircleID else { return }
                    run {
                        if isCurrentAccountOwner {
                            if await sync.deleteSyncedCircle(circleID: circleID) {
                                closeThenRemoveLocalCircle(circleID)
                            }
                        } else {
                            if await sync.leaveSyncedCircle(circleID: circleID) {
                                closeThenRemoveLocalCircle(circleID)
                            }
                        }
                        invitation = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(isCurrentAccountOwner
                    ? "This permanently removes the encrypted service copy and this iPhone’s local copy. Other members’ already-downloaded offline copies cannot be remotely erased, but they lose service access and stop syncing."
                    : "This removes your membership, forgets the circle key, and removes this circle’s local copy from this iPhone. Other circles are unchanged.")
            }
            .confirmationDialog(
                "Remove this local circle from this iPhone?",
                isPresented: Binding(
                    get: { localCirclePendingDeletion != nil },
                    set: { if !$0 { localCirclePendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Circle", role: .destructive) {
                    guard let circleID = localCirclePendingDeletion else { return }
                    closeThenRemoveLocalCircle(circleID)
                    localCirclePendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { localCirclePendingDeletion = nil }
            } message: {
                Text("This circle is not synced. Its restaurants, outings, photos, and rankings will be removed from this iPhone. Other circles are unchanged.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Private circle")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(store.activeCircle?.name ?? "Your Circle").font(BBTheme.display(36))
                Button {
                    circleNameDraft = store.activeCircle?.name ?? ""
                    circleRenameError = nil
                    isRenamingCircle = true
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title2)
                        .foregroundStyle(BBTheme.oxblood)
                }
                .accessibilityLabel("Rename circle")
            }
            Text("Invite up to six people. Everyone sees shared outings, while each diner\u{2019}s entry and rankings stay personal.")
                .foregroundStyle(.secondary)
            if let circleRenameError {
                Text(circleRenameError).font(.caption).foregroundStyle(BBTheme.oxblood)
            }
        }
    }

    private var circleLibraryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow("Your circles")
                    Text("Switching changes the whole dining log")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    newCircleName = ""
                    newCircleOwnerName = store.currentPerson?.name ?? ""
                    isCreatingCircle = true
                } label: {
                    Label("New", systemImage: "plus.circle.fill")
                }
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("new-circle-button")
            }
            ForEach(store.circles) { circle in
                Button {
                    invitation = nil
                    store.activateCircle(circle.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: circle.id == store.activeCircleID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(circle.id == store.activeCircleID ? BBTheme.oxblood : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(circle.name).font(.headline).foregroundStyle(BBTheme.ink)
                            Text(circle.id == store.activeCircleID ? "Open now" : "Tap to open")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if sync.hasCircleKey(circleID: circle.id) {
                            Image(systemName: sync.isPaused(circleID: circle.id) ? "pause.circle.fill" : "lock.shield.fill")
                                .foregroundStyle(BBTheme.oxblood)
                                .accessibilityLabel("Sync connected")
                        } else {
                            Text("Local").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .editorialCard()
    }

    private var memberCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Members")
            Text("A name is a local profile. A Connected badge means that person has accepted an invitation and can sync the circle on their device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(store.circleMembers) { person in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color(hex: person.colorHex))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.name + (person.id == store.currentPerson?.id ? " (this device)" : ""))
                            .font(.headline)
                        if let membership = membership(for: person.id) {
                            Text(membership.role == "owner" ? "Owner · Connected" : "Connected")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BBTheme.oxblood)
                            Text(presenceDescription(for: membership))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(circleHasKey ? "Invitation needed" : "Local profile")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let membership = membership(for: person.id) {
                        if isCurrentAccountOwner, membership.userID != sync.accountUserID {
                            Button(role: .destructive) { memberToRemove = membership } label: {
                                Image(systemName: "person.crop.circle.badge.minus")
                            }
                            .accessibilityLabel("Remove \(person.name) from syncing")
                        }
                    }
                }
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
            Text(circleHasKey ? "Resume this circle" : "Connect this circle").font(.headline)
            Text(circleHasKey
                ? "This iPhone still holds the circle’s private key. Sign in with Apple to resume encrypted syncing without changing that key."
                : "Sign in with Apple, create this circle’s private key, and upload the existing log in encrypted form. The service never receives readable dining records.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                guard let circle = store.activeCircle, let personID = store.currentPerson?.id else { return }
                run {
                    await sync.signInWithApple()
                    if sync.isSignedIn {
                        if sync.hasCircleKey(circleID: circle.id) {
                            _ = await sync.resumeSync(circleID: circle.id)
                            await sync.refreshMembers(circleID: circle.id)
                        } else {
                            await sync.enableSync(circleID: circle.id, circleName: circle.name, personID: personID)
                        }
                    }
                }
            } label: {
                if isWorking {
                    HStack { ProgressView(); Text("Connecting…") }.frame(maxWidth: .infinity)
                } else {
                    Label("Sign In & Turn On Syncing", systemImage: "apple.logo").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking || store.currentPerson == nil)
            if isWorking {
                firstSyncExplanation
            }
        }
        .editorialCard()
    }

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Syncing")
            Text("Turn on syncing for this circle").font(.headline)
            Text("A key is created on this iPhone and stored in its Keychain. The existing log and future changes are encrypted before upload.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                guard let circle = store.activeCircle, let personID = store.currentPerson?.id else { return }
                run { await sync.enableSync(circleID: circle.id, circleName: circle.name, personID: personID) }
            } label: {
                if isWorking {
                    HStack {
                        ProgressView()
                        Text(sync.status.isBusy ? "Encrypting & Uploading…" : "Connecting…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Turn On Syncing", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking || store.activeCircle == nil)
            if isWorking {
                firstSyncExplanation
            }
        }
        .editorialCard()
    }

    private var syncedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Syncing")
            LabeledContent("Connection", value: circleIsSynced ? "Connected" : "Paused on this iPhone")
            LabeledContent("Accounts", value: "\(activeMemberships.count) connected")
            LabeledContent("Last sync", value: sync.status.description)
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
            .disabled(isWorking || sync.status.isBusy || !circleIsSynced)
            Button(circleIsSynced ? "Pause Syncing on This iPhone" : "Resume Syncing on This iPhone") {
                guard let circleID = store.activeCircleID else { return }
                if circleIsSynced {
                    sync.pauseSync(circleID: circleID)
                } else {
                    run { _ = await sync.resumeSync(circleID: circleID) }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Sign Out") { run { await sync.signOut() } }
                .buttonStyle(SecondaryButtonStyle())
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
            if eligibleInvitees.isEmpty {
                Text("Every circle member already has sync access. Add another member to create a new invitation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let invitation, let url = invitation.url {
                ShareLink(item: url) {
                    Label("Send Invitation", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("The first signed-in person who redeems this link claims this member’s place in the circle. Create a new invitation if it goes astray.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Invite", selection: Binding(
                    get: { inviteeID ?? eligibleInvitees.first?.id },
                    set: { inviteeID = $0 }
                )) {
                    ForEach(eligibleInvitees) { person in
                        Text(person.name).tag(UUID?.some(person.id))
                    }
                }
                Button {
                    guard let circle = store.activeCircle,
                          let personID = inviteeID ?? eligibleInvitees.first?.id else { return }
                    run {
                        invitation = await sync.makeInvitation(
                            circleID: circle.id,
                            personID: personID,
                            circleName: circle.name
                        )
                    }
                } label: {
                    if isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Create Invitation", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking || eligibleInvitees.isEmpty)
            }
        }
        .editorialCard()
    }

    private var serviceDataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Circle actions")
            Text(isCurrentAccountOwner ? "Delete this circle" : "Leave this circle")
                .font(.headline)
            Text(isCurrentAccountOwner
                ? "Permanently remove its encrypted service data, memberships, stored photos, and this iPhone’s local copy."
                : "Remove your membership, forget its key, and remove this circle from this iPhone.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(isCurrentAccountOwner ? "Delete Circle" : "Leave Circle", role: .destructive) {
                isConfirmingServiceDeletion = true
            }
            .accessibilityIdentifier(isCurrentAccountOwner ? "delete-circle-button" : "leave-circle-button")
            .disabled(isWorking)
        }
        .editorialCard()
    }

    private var localCircleActionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Circle actions")
            Text("Remove this local circle").font(.headline)
            Text("This circle has no service membership. Removing it affects only this iPhone.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Remove Circle from This iPhone", role: .destructive) {
                localCirclePendingDeletion = store.activeCircleID
            }
            .accessibilityIdentifier("remove-local-circle-button")
            .disabled(isWorking)
        }
        .editorialCard()
    }

    private var eligibleInvitees: [PersonEntity] {
        store.circleMembers.filter { person in
            !activeMemberships.contains(where: { $0.personID == person.id })
        }
    }

    private var isCurrentAccountOwner: Bool {
        currentAccountMembership?.role == "owner"
    }

    private var currentAccountMembership: SupabaseClient.MembershipRow? {
        guard let userID = sync.accountUserID else { return nil }
        return activeMemberships.first { $0.userID == userID }
    }

    private func membership(for personID: UUID) -> SupabaseClient.MembershipRow? {
        activeMemberships.first { $0.personID == personID }
    }

    private var activeMemberships: [SupabaseClient.MembershipRow] {
        guard let circleID = store.activeCircleID else { return [] }
        return sync.memberships(circleID: circleID)
    }

    private var circleTaskID: String {
        let circle = store.activeCircleID?.uuidString ?? "none"
        return "\(circle)-\(sync.isSignedIn)-\(circleIsSynced)"
    }

    private var firstSyncExplanation: some View {
        Text("The first sync can take a minute when the log contains many visits or photos. Keep the app open; this screen will change to Connected when it finishes.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func presenceDescription(for membership: SupabaseClient.MembershipRow) -> String {
        var details: [String] = []
        if let version = membership.appVersion { details.append("App \(version)") }
        if let date = membership.lastSeenAt {
            details.append("Active \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
        } else {
            details.append("Awaiting first app check-in")
        }
        return details.joined(separator: " · ")
    }

    private func saveCircleName() {
        guard let circle = store.activeCircle else { return }
        if store.renameCircle(circle, to: circleNameDraft) {
            circleRenameError = nil
            Haptics.success()
        } else {
            circleRenameError = "Enter a non-empty name that is different from your other circles."
        }
    }

    private func createCircle() {
        let owner = newCircleOwnerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackOwner = store.currentPerson?.name ?? "Me"
        if store.createCircle(
            name: newCircleName,
            ownerName: owner.isEmpty ? fallbackOwner : owner
        ) != nil {
            invitation = nil
            circleRenameError = nil
            Haptics.success()
        } else {
            sync.lastError = "Use a non-empty circle name that is different from your other circles."
        }
    }

    /// Core Data invalidates a deleted managed object immediately. Let the
    /// management sheet finish dismissing before deleting the graph so SwiftUI
    /// cannot re-evaluate an outgoing row that still captures that object.
    private func closeThenRemoveLocalCircle(_ circleID: UUID) {
        Task { @MainActor in
            // A confirmation dialog is itself a presentation layer. Allow its
            // destructive action to dismiss first, then close the parent sheet.
            try? await Task.sleep(for: .milliseconds(150))
            router.dismissCircleManagement(removing: circleID)
        }
    }

    private func selectFirstInviteeIfNeeded() {
        if !eligibleInvitees.contains(where: { $0.id == inviteeID }) {
            inviteeID = eligibleInvitees.first?.id
            invitation = nil
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

/// Presented when an invitation link is opened on this device.
@MainActor
struct JoinCircleView: View {
    let invitation: CircleInvitation
    let onJoined: () -> Void
    let onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
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
                                    if store.completeCircleJoin(
                                        circleID: invitation.circleID,
                                        personID: invitation.personID
                                    ) {
                                        onJoined()
                                        dismiss()
                                    } else {
                                        error = store.lastError
                                    }
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
                        .accessibilityIdentifier("join-circle-button")
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") {
                        onDiscard()
                        dismiss()
                    }
                }
            }
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
