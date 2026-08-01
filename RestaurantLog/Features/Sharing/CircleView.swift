import SwiftUI

/// One person in the circle, as plain values a view can safely render.
struct CircleMemberRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let colorHex: String
    let isMe: Bool
    /// False for an account that has joined but whose profile has not synced here yet.
    let isMember: Bool
    let membership: SupabaseClient.MembershipRow?
    let presence: String?

    var isConnected: Bool { membership != nil }

    var statusTitle: String {
        guard let membership else { return "Name only · not synced" }
        return membership.role == "owner" ? "Owner · synced" : "Synced"
    }

    var statusDetail: String? {
        isMember ? presence : "They will appear after the next sync."
    }

    static func == (lhs: CircleMemberRow, rhs: CircleMemberRow) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isMember == rhs.isMember
            && lhs.membership?.userID == rhs.membership?.userID
            && lhs.presence == rhs.presence
    }
}

private struct CircleProfileMergeRequest: Identifiable {
    let sourceID: UUID
    let sourceName: String
    let targetID: UUID
    let targetName: String

    var id: UUID { sourceID }
}

/// The records that joining a circle makes visible to the circle.
///
/// Joining deliberately adopts the whole local log, so the UI needs to name
/// the complete impact before it asks the sync layer to redeem a code.
@MainActor
struct CircleJoinDisclosure: Equatable {
    let restaurants: Int
    let outings: Int
    let photos: Int
    let wantToTry: Int
    let reactions: Int
    let rankingEvidence: Int

    init(impact: CircleJoinImpact) {
        restaurants = impact.restaurants
        outings = impact.outings
        photos = impact.photos
        wantToTry = impact.wantToTryEntries
        reactions = impact.reactions
        rankingEvidence = impact.rankingAnswers
    }

    @MainActor
    init(store: AppStore) {
        self.init(impact: store.circleJoinImpact)
    }

    var isEmpty: Bool {
        restaurants == 0
            && outings == 0
            && photos == 0
            && wantToTry == 0
            && reactions == 0
            && rankingEvidence == 0
    }

    /// Used in the onboarding card before a join code is entered.
    var onboardingDisclosure: String {
        if isEmpty {
            return "Everything already on this iPhone becomes visible to their circle, and their history appears here."
        }
        return "\(countList) already on this iPhone become visible to their circle, and their history appears here."
    }

    /// Used in the final confirmation immediately before joining.
    var confirmationDisclosure: String {
        "This iPhone will share \(countList) with the circle, and their history appears here. Leaving later does not take back what you shared."
    }

    private var countList: String {
        let items = [
            quantity(restaurants, singular: "restaurant"),
            quantity(outings, singular: "outing"),
            quantity(photos, singular: "photo"),
            quantity(wantToTry, singular: "Want to Try entry", plural: "Want to Try entries"),
            quantity(reactions, singular: "reaction"),
            quantity(rankingEvidence, singular: "comparison")
        ]
        guard let last = items.last else { return "no records" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + ", and " + last
    }

    private func quantity(_ count: Int, singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// Everything about who shares this dining log, on one screen.
///
/// The model behind it is deliberately small: there is one log, it belongs to
/// the signed-in account, and other people are added to it with a join code.
/// There is no switch for syncing, no second local circle, and no state where a
/// member has to guess whether their restaurants are being shared or not.
@MainActor
struct CircleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @State private var isWorking = false
    @State private var invitation: CircleInvitation?
    @State private var joinCode = ""
    @State private var joinMessage: String?
    @State private var isRenaming = false
    @State private var nameDraft = ""
    @State private var newMemberName = ""
    @State private var memberToRemove: CircleMemberRow?
    @State private var memberToConnectHistory: CircleMemberRow?
    @State private var isConfirmingLeave = false
    @State private var didCopyCode = false
    @State private var actionMessage: String?
    @State private var joinCodeAwaitingConfirmation: CircleJoinCode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    membersCard
                    if sync.isConfigured {
                        if sync.isSignedIn {
                            inviteCard
                            // Once this log is shared there is nothing to join:
                            // taking a code now would move everybody's records
                            // into a third circle, which is never what somebody
                            // tapping around in here meant to do.
                            if !sync.isShared { joinCard }
                            leaveCard
                        } else {
                            signInCard
                            joinCard
                        }
                    } else {
                        unavailableCard
                    }
                    if let message = actionMessage {
                        Text(message).font(.caption).foregroundStyle(BBTheme.oxblood)
                    }
                    Text("Outings, reactions, and photos are encrypted on this iPhone before upload. The key stays on your devices, so the server stores something it cannot read.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .readablePageWidth()
            }
            .editorialPage()
            .navigationTitle("Circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: rosterTaskID) { await refresh() }
            .sheet(item: $memberToConnectHistory) { member in
                CircleHistoryMergeView(member: member) { message in
                    actionMessage = message
                }
            }
        }
        .editorialPrompt(isPresented: $isRenaming) {
            EditorialPrompt(
                "Rename circle",
                message: "Everyone in the circle sees this name.",
                field: EditorialPrompt.Field(
                    "Circle name",
                    text: $nameDraft,
                    capitalization: .words
                ),
                actions: [
                    .primary("Save") { saveName() },
                    .cancel()
                ]
            )
        }
        .editorialPrompt(item: $memberToRemove) { member in
            .destructive(
                "Remove this person?",
                message: removalExplanation(for: member),
                actionTitle: "Remove from circle"
            ) {
                remove(member)
            }
        }
        .editorialPrompt(isPresented: $isConfirmingLeave) {
            .destructive(
                sync.isOwner ? "Stop sharing this log?" : "Leave this circle?",
                message: sync.isOwner
                    ? "Everyone else loses access and the shared copy is deleted from the server. Everything stays on this iPhone and keeps syncing as your own log."
                    : "You keep everything on this iPhone, including what the circle shared with you, and it keeps syncing privately. You just stop exchanging changes with them.",
                actionTitle: sync.isOwner ? "Stop sharing" : "Leave circle"
            ) {
                leave()
            }
        }
        .editorialPrompt(item: $joinCodeAwaitingConfirmation) { code in
            EditorialPrompt(
                "Share your existing log and join?",
                message: CircleJoinDisclosure(store: store).confirmationDisclosure,
                actions: [
                    .primary("Share existing log and join") { join(code: code) },
                    .cancel()
                ]
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Circle")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(store.activeCircle?.name ?? "Your log")
                    .font(BBTheme.display(36))
                if sync.isShared {
                    Button {
                        nameDraft = store.activeCircle?.name ?? ""
                        isRenaming = true
                    } label: {
                        Image(systemName: "pencil.circle.fill").font(.title2).foregroundStyle(BBTheme.oxblood)
                    }
                    .accessibilityLabel("Rename circle")
                }
            }
            Text(rosterSummary)
                .foregroundStyle(.secondary)
            Label(statusTitle, systemImage: statusSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(sync.isSignedIn ? BBTheme.oxblood : .secondary)
                .accessibilityIdentifier("sharing-access-status")
            Text(visibilitySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sharing-visibility-detail")
            if case .failed = sync.status, let message = sync.lastError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(BBTheme.oxblood)
            }
        }
    }

    private var rosterSummary: String {
        let count = store.circleMembers.count
        if count == 1, let name = store.circleMembers.first?.name {
            return "\(name) is the only person in this log."
        }
        return "\(count) people here, each with their own reactions and rankings."
    }

    private var visibilitySummary: String {
        if sync.members.count > 1 {
            return "\(sync.members.count) people can open this log on their own device. A name on its own does not give anybody access."
        }
        if sync.isSignedIn {
            return "Only you can open this log on another device. The other names are just labels for reactions."
        }
        return "This log exists only on this iPhone. The names here are just labels for reactions."
    }

    private var statusTitle: String {
        guard sync.isConfigured else { return "Only this iPhone has a copy" }
        guard sync.isSignedIn else { return "Only this iPhone has a copy" }
        if sync.isPreparing || sync.status.isBusy { return "Syncing…" }
        switch sync.status {
        case let .upToDate(date):
            if sync.members.count > 1 { return "\(sync.members.count) people synced" }
            return "Backed up \(date.formatted(.relative(presentation: .named, unitsStyle: .narrow)))"
        case .offline: return "Offline · saved on this iPhone"
        case .failed: return "Needs attention"
        default: return sync.members.count > 1 ? "\(sync.members.count) people synced" : "Backed up and encrypted"
        }
    }

    private var statusSymbol: String {
        guard sync.isSignedIn else { return "iphone" }
        if case .failed = sync.status { return "exclamationmark.triangle.fill" }
        if case .offline = sync.status { return "icloud.slash" }
        return "lock.icloud.fill"
    }

    // MARK: - Members

    private var membersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("People in this log")
            ForEach(memberRows) { member in
                memberRow(member)
            }
            Text(profileAccessNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .editorialCard()
    }

    private var profileAccessNote: String {
        if sync.isShared {
            return "Only the people marked as synced can open this log on another device."
        }
        return "Each name keeps its own reactions and rankings. A name on its own does not give anybody access."
    }

    private func memberRow(_ member: CircleMemberRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: member.isMember ? "person.crop.circle.fill" : "person.crop.circle.badge.questionmark")
                .font(.title2)
                .foregroundStyle(member.isMember ? Color(hex: member.colorHex) : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.name + (member.isMe ? " (you)" : "")).font(.headline)
                Text(member.statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(member.isConnected ? BBTheme.oxblood : .secondary)
                if let detail = member.statusDetail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if canConnectHistory(member) || canRemove(member) {
                VStack(alignment: .trailing, spacing: 6) {
                    if canConnectHistory(member) {
                        Button("Connect history") { memberToConnectHistory = member }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .frame(minHeight: 38)
                            .accessibilityLabel("Connect saved history to \(member.name)")
                    }
                    if canRemove(member) {
                        Button("Remove", role: .destructive) { memberToRemove = member }
                            .font(.callout.weight(.semibold))
                            .buttonStyle(.bordered)
                            .tint(BBTheme.oxblood)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Remove \(member.name) from this circle")
                            .accessibilityIdentifier("remove-member-button")
                    }
                }
            }
        }
    }

    /// The owner can remove anybody but themselves. Anyone can tidy up a
    /// profile that has no account attached, because that is just a name.
    private func canRemove(_ member: CircleMemberRow) -> Bool {
        guard !member.isMe else { return false }
        if member.membership != nil { return sync.isOwner }
        return member.isMember
    }

    private func historyCandidates(for member: CircleMemberRow) -> [PersonEntity] {
        guard member.isMember else { return [] }
        let connectedPersonIDs = Set(sync.members.map(\.personID))
        return store.people.filter {
            $0.id != member.id
                && $0.id != store.currentPerson?.id
                && !connectedPersonIDs.contains($0.id)
                && store.personHasHistory($0.id)
        }
    }

    private func canConnectHistory(_ member: CircleMemberRow) -> Bool {
        guard member.membership != nil,
              member.isMe || sync.isOwner else { return false }
        return !historyCandidates(for: member).isEmpty
    }

    /// The roster rendered as plain values.
    ///
    /// SwiftUI can re-evaluate a row one more time after its person has been
    /// removed, and reading a deleted Core Data object from a view body is what
    /// crashed the previous build. Copying the few fields a row needs makes
    /// that impossible.
    private var memberRows: [CircleMemberRow] {
        let people = store.circleMembers
        var rows = people.map { person in
            CircleMemberRow(
                id: person.id,
                name: person.name,
                colorHex: person.colorHex,
                isMe: person.id == store.currentPerson?.id,
                isMember: true,
                membership: sync.members.first { $0.personID == person.id },
                presence: sync.members.first { $0.personID == person.id }.map(presence(for:))
            )
        }
        // An account that has joined but whose profile has not arrived here yet.
        let known = Set(people.map(\.id))
        rows += sync.members.filter { !known.contains($0.personID) }.map { membership in
            CircleMemberRow(
                id: membership.personID,
                name: "Someone new",
                colorHex: "7A7166",
                isMe: membership.userID == sync.accountUserID,
                isMember: false,
                membership: membership,
                presence: presence(for: membership)
            )
        }
        return rows
    }

    private func name(for membership: SupabaseClient.MembershipRow) -> String {
        store.circleMembers.first { $0.id == membership.personID }?.name ?? "That person"
    }

    private func presence(for membership: SupabaseClient.MembershipRow) -> String {
        var details: [String] = []
        if let version = membership.appVersion { details.append("App \(version)") }
        if let date = membership.lastSeenAt {
            details.append("Active \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
        } else {
            details.append("Has not opened it yet")
        }
        return details.joined(separator: " · ")
    }

    // MARK: - Inviting

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Add someone")
            if let invitation {
                Text(invitation.code.formatted)
                    .font(BBTheme.score(30))
                    .monospaced()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(BBTheme.ink.opacity(0.05))
                    .accessibilityLabel("Join code \(spokenCode(invitation.code))")
                Text("They open the app, tap Add someone, and type this code. It works once and expires in seven days.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = invitation.code.formatted
                        didCopyCode = true
                        Haptics.success()
                    } label: {
                        Label(didCopyCode ? "Copied" : "Copy code", systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    if let url = invitation.url {
                        ShareLink(item: url, message: Text("Join my circle with the code \(invitation.code.formatted)")) {
                            Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                Button("Cancel this code") {
                    guard let circleID = store.activeCircleID else { return }
                    run {
                        actionMessage = nil
                        if await sync.cancelInvitations(circleID: circleID) {
                            self.invitation = nil
                            didCopyCode = false
                        } else {
                            actionMessage = sync.lastError
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .frame(minHeight: 40)
            } else {
                Text("Give somebody their own copy. Everything here goes with them, and everything they log comes back to you.")
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    guard let circle = store.activeCircle else { return }
                    run {
                        actionMessage = nil
                        invitation = await sync.makeInvitation(circleID: circle.id, circleName: circle.name)
                        if invitation == nil { actionMessage = sync.lastError }
                        didCopyCode = false
                    }
                } label: {
                    if isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Create a join code", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking || !canInvite)
                if !canInvite {
                    Text("Still uploading. Try again in a moment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .editorialCard()
    }

    private var canInvite: Bool {
        guard let circleID = store.activeCircleID else { return false }
        return sync.hasKey(circleID: circleID)
    }

    /// VoiceOver reads a run of characters as a word otherwise.
    private func spokenCode(_ code: CircleJoinCode) -> String {
        code.normalized.map(String.init).joined(separator: " ")
    }

    // MARK: - Joining

    private var joinCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Join a circle")
            Text("Got a join code?").font(.headline)
            Text(CircleJoinDisclosure(store: store).onboardingDisclosure)
                .font(.callout).foregroundStyle(.secondary)
            TextField("XXXX-XXXX-XXXX", text: $joinCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .monospaced()
                .padding(12)
                .background(BBTheme.ink.opacity(0.05))
                .accessibilityIdentifier("join-code-field")
                .onChange(of: joinCode) { _, value in
                    let formatted = CircleJoinCode(value)?.formatted
                    if let formatted, formatted != value { joinCode = formatted }
                }
            Button {
                guard let code = CircleJoinCode(joinCode) else { return }
                requestJoin(code: code)
            } label: {
                if isWorking {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label(
                        CircleJoinDisclosure(store: store).isEmpty ? "Join circle" : "Review sharing and join",
                        systemImage: "person.2.fill"
                    ).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking || CircleJoinCode(joinCode) == nil)
            .accessibilityIdentifier("join-circle-button")
            if let joinMessage {
                Text(joinMessage).font(.caption).foregroundStyle(BBTheme.oxblood)
            }
        }
        .editorialCard()
    }

    // MARK: - Account

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Sign in")
            Text("Back up and share this log").font(.headline)
            Text("Signing in encrypts this log on the iPhone and keeps a copy on the sync service, so it survives a lost phone and can be shared with the people you dine with.")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                run { await signIn() }
            } label: {
                if isWorking {
                    HStack { ProgressView(); Text("Signing in…") }.frame(maxWidth: .infinity)
                } else {
                    Label("Sign in with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking)
        }
        .editorialCard()
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Sync")
            Text("Not available in this build").font(.headline)
            Text("This copy of the app has no sync service configured, so the log stays on this iPhone. Backups in Settings still move it between devices.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .editorialCard()
    }

    private var leaveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Circle actions")
            Text(sync.isOwner ? "Stop sharing this log" : "Leave this circle").font(.headline)
            Text("Your dining log stays on this iPhone either way, and keeps syncing to your own account.")
                .font(.callout).foregroundStyle(.secondary)
            Button(sync.isOwner ? "Stop sharing" : "Leave circle", role: .destructive) {
                isConfirmingLeave = true
            }
            .accessibilityIdentifier("leave-circle-button")
            .disabled(isWorking || !sync.isShared)
            if !sync.isShared {
                Text("Nobody else has joined yet, so there is nothing to leave.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .editorialCard()
    }

    // MARK: - Actions

    private var rosterTaskID: String {
        "\(store.activeCircleID?.uuidString ?? "none")-\(sync.isSignedIn)-\(store.revision)"
    }

    private func refresh() async {
        guard let circleID = store.activeCircleID, sync.isSignedIn else { return }
        await sync.refreshMembers(circleID: circleID)
        store.adoptDeviceIdentity(preferring: sync.myMembership?.personID)
    }

    private func signIn() async {
        actionMessage = nil
        guard await sync.signInWithApple() else {
            actionMessage = sync.lastError
            return
        }
        guard let circle = store.activeCircle,
              let personID = store.currentPerson?.id else {
            actionMessage = SyncError.deviceIdentityMissing.localizedDescription
            return
        }
        if case .failed = await sync.activate(circleID: circle.id, name: circle.name, personID: personID) {
            actionMessage = sync.lastError
        }
    }

    private func saveName() {
        guard let circle = store.activeCircle else { return }
        if store.renameCircle(circle, to: nameDraft) { Haptics.success() }
    }

    private func removalExplanation(for member: CircleMemberRow) -> String {
        var parts: [String] = []
        if member.membership != nil {
            parts.append("\(member.name) stops receiving this log and can no longer add to it. The copy already on their iPhone stays there.")
        }
        if member.isMember {
            parts.append(store.personHasHistory(member.id)
                ? "Everything they logged stays in this circle, and you can still add them to an outing."
                : "Their profile has no outings yet, so it is removed completely.")
        }
        return parts.joined(separator: " ")
    }

    private func remove(_ member: CircleMemberRow) {
        guard let circleID = store.activeCircleID else { return }
        run {
            // Service access first: if that fails, the person is still a member
            // here and the owner can try again, rather than the roster claiming
            // somebody was removed while their device kept syncing.
            if let membership = member.membership {
                guard await sync.removeMember(circleID: circleID, userID: membership.userID) else {
                    actionMessage = sync.lastError
                    return
                }
            }
            if member.isMember { _ = store.removeCircleMember(member.id) }
            memberToRemove = nil
            Haptics.success()
        }
    }

    /// Leaving never deletes the dining log. The records stay exactly where
    /// they are and the circle is given a new identity, which is what makes
    /// this safe: nothing is removed from Core Data while the interface is
    /// still showing it.
    private func leave() {
        guard let circleID = store.activeCircleID else { return }
        run {
            let succeeded = sync.isOwner
                ? await sync.deleteServerCopy(circleID: circleID)
                : await sync.leave(circleID: circleID)
            guard succeeded else {
                actionMessage = sync.lastError
                return
            }
            guard let newID = store.startFreshCircleIdentity(),
                  let circle = store.activeCircle,
                  let personID = store.currentPerson?.id else {
                actionMessage = SyncError.deviceIdentityMissing.localizedDescription
                return
            }
            if case .failed = await sync.activate(circleID: newID, name: circle.name, personID: personID) {
                actionMessage = sync.lastError
                return
            }
            Haptics.success()
            dismiss()
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }

    private func requestJoin(code: CircleJoinCode) {
        if CircleJoinDisclosure(store: store).isEmpty {
            join(code: code)
        } else {
            joinCodeAwaitingConfirmation = code
        }
    }

    private func join(code: CircleJoinCode) {
        run {
            joinMessage = await joinCircle(code: code, store: store, sync: sync)
            if joinMessage == nil {
                joinCode = ""
                Haptics.success()
                dismiss()
            }
        }
    }
}

@MainActor
private struct CircleHistoryMergeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    let member: CircleMemberRow
    let onFinished: (String) -> Void
    @State private var request: CircleProfileMergeRequest?

    private var candidates: [PersonEntity] {
        let connectedPersonIDs = Set(sync.members.map(\.personID))
        return store.people.filter {
            $0.id != member.id
                && $0.id != store.currentPerson?.id
                && !connectedPersonIDs.contains($0.id)
                && store.personHasHistory($0.id)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(candidates) { companion in
                        Button {
                            request = .init(
                                sourceID: companion.id,
                                sourceName: companion.name,
                                targetID: member.id,
                                targetName: member.name
                            )
                        } label: {
                            HStack {
                                Label(companion.name, systemImage: "person.crop.circle")
                                Spacer()
                                Image(systemName: "arrow.right")
                                Text(member.name).fontWeight(.semibold)
                            }
                        }
                    }
                } header: {
                    Text("Saved people")
                } footer: {
                    Text("Choose the saved person whose previous reactions and outings belong to \(member.name). Nothing moves until you confirm.")
                }
            }
            .editorialForm()
            .navigationTitle("Connect History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .editorialPrompt(item: $request) { request in
            .destructive(
                "Merge these profiles?",
                message: "Every reaction, ranking decision, outing, dish, photo, memory, and Want to Try entry saved under \(request.sourceName) moves to \(request.targetName). The redundant \(request.sourceName) profile is then removed. This cannot be undone.",
                actionTitle: "Merge \(request.sourceName) into \(request.targetName)"
            ) {
                merge(request)
            }
        }
    }

    private func merge(_ request: CircleProfileMergeRequest) {
        self.request = nil
        if store.mergeHistoricalProfile(
            request.sourceID,
            into: request.targetID,
            connectedMemberIDs: Set(sync.members.map(\.personID))
        ) {
            onFinished("\(request.sourceName)'s saved history now belongs to \(request.targetName).")
            Haptics.success()
            dismiss()
        } else {
            onFinished(store.lastError ?? "Those profiles could not be merged. Nothing was changed.")
        }
    }
}

/// Redeems a code and merges this device's dining log into the circle it
/// unlocks. Returns a message when something stopped it, or nil on success.
///
/// The merge is the point. A member who joins and then imports a restaurant
/// list expects the other members to see it, so the log this iPhone already
/// holds becomes part of the shared circle instead of staying behind in a
/// private one.
@MainActor
func joinCircle(code: CircleJoinCode, store: AppStore, sync: SyncCoordinator) async -> String? {
    guard sync.isConfigured else { return SyncError.notConfigured.localizedDescription }
    if !sync.isSignedIn {
        guard await sync.signInWithApple() else {
            return sync.lastError ?? SyncError.notSignedIn.localizedDescription
        }
    }
    guard let personID = store.currentPerson?.id else {
        return SyncError.deviceIdentityMissing.localizedDescription
    }
    let previousCircleID = store.activeCircleID

    switch await sync.join(code, personID: personID) {
    case let .failed(message):
        return message
    case let .joined(circleID, circleName):
        guard let adoptedPersonID = store.adoptCircle(id: circleID, name: circleName),
              adoptedPersonID == personID else {
            return "This iPhone could not open the circle it just joined. Try syncing again."
        }
        guard let circle = store.activeCircle else { return nil }
        guard case let .ready(serverPersonID) = await sync.activate(
            circleID: circleID,
            name: circle.name,
            personID: adoptedPersonID
        ), serverPersonID == personID else {
            return sync.lastError ?? "This iPhone could not finish joining the circle. Your local log is unchanged."
        }
        if let previousCircleID, previousCircleID != circleID {
            await sync.discardAbandonedCircle(previousCircleID)
        }
        // The first pull brings the circle's own name and member profiles, which
        // can rename people this device already knew.
        store.reload()
        return nil
    }
}

/// Accepting an invitation, whether it arrived as a link or as twelve
/// characters somebody read out over dinner.
@MainActor
struct JoinCircleView: View {
    /// Prefilled when a link opened the app; nil when the code is being typed.
    var invitation: CircleInvitation?
    var onJoined: () -> Void = {}
    var onDiscard: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @State private var typedCode = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var pendingJoinCode: CircleJoinCode?

    private var code: CircleJoinCode? { invitation?.code ?? CircleJoinCode(typedCode) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(invitation == nil ? "Join a circle" : "Invitation")
                        Text(invitation?.circleName ?? "Join a circle").font(BBTheme.display(34))
                        Text(sync.isConfigured
                            ? "You will share one log. Everything on this iPhone goes with you, everything already in the circle comes back, and each person keeps their own reactions and rankings."
                            : "Circle sharing is unavailable in this build. Your local log stays on this iPhone.")
                            .foregroundStyle(.secondary)
                    }
                    if sync.isConfigured {
                        if let invitation {
                            Text(invitation.code.formatted)
                                .font(BBTheme.score(26))
                                .monospaced()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(BBTheme.ink.opacity(0.05))
                        } else {
                            TextField("XXXX-XXXX-XXXX", text: $typedCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .monospaced()
                                .font(BBTheme.score(24))
                                .multilineTextAlignment(.center)
                                .padding(14)
                                .background(BBTheme.ink.opacity(0.05))
                                .accessibilityIdentifier("join-code-field")
                                .onChange(of: typedCode) { _, value in
                                    if let formatted = CircleJoinCode(value)?.formatted, formatted != value {
                                        typedCode = formatted
                                    }
                                }
                        }
                        Button {
                            guard let code else { return }
                            requestJoin(code: code)
                        } label: {
                            if isWorking {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                let title = CircleJoinDisclosure(store: store).isEmpty
                                    ? (sync.isSignedIn ? "Join this circle" : "Sign in and join")
                                    : "Review sharing and join"
                                Label(
                                    title,
                                    systemImage: CircleJoinDisclosure(store: store).isEmpty && !sync.isSignedIn
                                        ? "apple.logo"
                                        : "person.2.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("join-circle-button")
                        .disabled(isWorking || code == nil)
                        if let error {
                            Text(error).font(.caption).foregroundStyle(BBTheme.oxblood)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Circle sharing is unavailable", systemImage: "icloud.slash")
                                .font(.headline)
                            Text("This build has no sync service configured, so you cannot join a circle here. Your log stays on this iPhone until you use a build with encrypted syncing enabled.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .editorialCard()
                    }
                }
                .padding(22)
                .readablePageWidth()
            }
            .editorialPage()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(sync.isConfigured ? "Join Circle" : "Sharing Unavailable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        onDiscard()
                        dismiss()
                    }
                }
            }
        }
        .editorialPrompt(item: $pendingJoinCode) { code in
            EditorialPrompt(
                "Share your existing log and join?",
                message: CircleJoinDisclosure(store: store).confirmationDisclosure,
                actions: [
                    .primary("Share existing log and join") { join(code: code) },
                    .cancel()
                ]
            )
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }

    private func requestJoin(code: CircleJoinCode) {
        if CircleJoinDisclosure(store: store).isEmpty {
            join(code: code)
        } else {
            pendingJoinCode = code
        }
    }

    private func join(code: CircleJoinCode) {
        run {
            error = await joinCircle(code: code, store: store, sync: sync)
            if error == nil {
                Haptics.success()
                onJoined()
                dismiss()
            }
        }
    }
}
