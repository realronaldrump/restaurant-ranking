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
        guard let membership else { return "Profile only · no device connected" }
        return membership.role == "owner" ? "Owner · syncing" : "Member · syncing"
    }

    var statusDetail: String? {
        isMember ? presence : "Their profile arrives with the next sync."
    }

    static func == (lhs: CircleMemberRow, rhs: CircleMemberRow) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isMember == rhs.isMember
            && lhs.membership?.userID == rhs.membership?.userID
            && lhs.presence == rhs.presence
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
    @State private var isConfirmingLeave = false
    @State private var didCopyCode = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if sync.isConfigured {
                        if sync.isSignedIn {
                            membersCard
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
                    if let message = sync.lastError {
                        Text(message).font(.caption).foregroundStyle(BBTheme.oxblood)
                    }
                    Text("Outings, ratings and photos are encrypted on this iPhone before they are uploaded. The key stays on the devices in this circle, so the sync service can store the log without ever reading it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .readablePageWidth()
            }
            .editorialPage()
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: rosterTaskID) { await refresh() }
            .alert("Rename Circle", isPresented: $isRenaming) {
                TextField("Circle name", text: $nameDraft).textInputAutocapitalization(.words)
                Button("Save") { saveName() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everyone in the circle sees this name.")
            }
            .confirmationDialog(
                "Remove this person?",
                isPresented: Binding(
                    get: { memberToRemove != nil },
                    set: { if !$0 { memberToRemove = nil } }
                ),
                titleVisibility: .visible,
                presenting: memberToRemove
            ) { member in
                Button("Remove From Circle", role: .destructive) { remove(member) }
                Button("Cancel", role: .cancel) { memberToRemove = nil }
            } message: { member in
                Text(removalExplanation(for: member))
            }
            .confirmationDialog(
                sync.isOwner ? "Stop sharing this log?" : "Leave this circle?",
                isPresented: $isConfirmingLeave,
                titleVisibility: .visible
            ) {
                Button(sync.isOwner ? "Stop Sharing" : "Leave Circle", role: .destructive) { leave() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(sync.isOwner
                    ? "Everyone else loses access and the shared copy is deleted from the sync service. Every restaurant, outing, photo and ranking stays on this iPhone and keeps syncing as your own private log."
                    : "You keep this log on your iPhone, including everything the circle shared with you, and it keeps syncing privately. You stop sending and receiving the circle's changes.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(sync.isShared ? "Shared dining log" : "Your dining log")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(sync.isShared ? (store.activeCircle?.name ?? "Your Circle") : "Just you")
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
            Text(sync.isShared
                ? "Everyone here sees the same restaurants and outings, and each person keeps their own reactions and rankings."
                : "Nobody else can see this log. Send somebody a join code and it becomes a shared dining history — everything already here goes with it.")
                .foregroundStyle(.secondary)
            Label(statusTitle, systemImage: statusSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(sync.isSignedIn ? BBTheme.oxblood : .secondary)
        }
    }

    private var statusTitle: String {
        guard sync.isConfigured else { return "This build syncs nothing" }
        guard sync.isSignedIn else { return "Not signed in" }
        if sync.isPreparing || sync.status.isBusy { return "Syncing…" }
        switch sync.status {
        case let .upToDate(date):
            return "Backed up · \(date.formatted(.relative(presentation: .named, unitsStyle: .narrow)))"
        case .offline: return "Offline · saved on this iPhone"
        case .failed: return "Needs attention"
        default: return "Backed up & encrypted"
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
            Eyebrow(sync.isShared ? "Who is in this circle" : "People in your log")
            ForEach(memberRows) { member in
                memberRow(member)
            }
            if !sync.isShared {
                Text("Only you can see this log. Send somebody a join code below and they share it from then on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .editorialCard()
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

    /// The owner can remove anybody but themselves. Anyone can tidy up a
    /// profile that has no account attached, because that is just a name.
    private func canRemove(_ member: CircleMemberRow) -> Bool {
        guard !member.isMe else { return false }
        if member.membership != nil { return sync.isOwner }
        return member.isMember
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
            details.append("Awaiting first check-in")
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
                Text("They open the app, tap Add Someone, and type this code. It works once and expires in seven days.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = invitation.code.formatted
                        didCopyCode = true
                        Haptics.success()
                    } label: {
                        Label(didCopyCode ? "Copied" : "Copy Code", systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    if let url = invitation.url {
                        ShareLink(item: url, message: Text("Join my dining log with the code \(invitation.code.formatted)")) {
                            Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                Button("Cancel This Code") {
                    guard let circleID = store.activeCircleID else { return }
                    run {
                        await sync.cancelInvitations(circleID: circleID)
                        self.invitation = nil
                        didCopyCode = false
                    }
                }
                .font(.caption.weight(.semibold))
                .frame(minHeight: 40)
            } else {
                Text("Give somebody their own copy of this log. Everything already here goes with them, and everything they log comes back to you.")
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    guard let circle = store.activeCircle else { return }
                    run {
                        invitation = await sync.makeInvitation(circleID: circle.id, circleName: circle.name)
                        didCopyCode = false
                    }
                } label: {
                    if isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Create a Join Code", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking || !canInvite)
                if !canInvite {
                    Text("This iPhone is still uploading the log. Try again in a moment.")
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
            Eyebrow("Join someone")
            Text("Got a join code?").font(.headline)
            Text("Everything on this iPhone — your restaurants, outings, photos and rankings — comes with you into their circle.")
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
                run {
                    joinMessage = await joinCircle(code: code, store: store, sync: sync)
                    if joinMessage == nil {
                        joinCode = ""
                        Haptics.success()
                        dismiss()
                    }
                }
            } label: {
                if isWorking {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Join Circle", systemImage: "person.2.fill").frame(maxWidth: .infinity)
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
            Text("Keep this log safe and shareable").font(.headline)
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
            Eyebrow("Syncing")
            Text("Not available in this build").font(.headline)
            Text("This copy of the app has no sync service configured, so the log stays on this iPhone. Backups in Settings still move it between devices.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .editorialCard()
    }

    private var leaveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Sharing actions")
            Text(sync.isOwner ? "Stop sharing this log" : "Leave this circle").font(.headline)
            Text("Your dining log stays on this iPhone either way, and keeps syncing to your own account.")
                .font(.callout).foregroundStyle(.secondary)
            Button(sync.isOwner ? "Stop Sharing" : "Leave Circle", role: .destructive) {
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
        await sync.refreshMembers(circleID: circleID, claiming: store.currentPerson?.id)
        store.adoptDeviceIdentity(preferring: sync.myMembership?.personID)
    }

    private func signIn() async {
        guard await sync.signInWithApple() else { return }
        guard let circle = store.activeCircle,
              let personID = store.currentPerson?.id ?? store.circleMembers.first?.id else { return }
        await sync.activate(circleID: circle.id, name: circle.name, personID: personID)
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
                ? "Everything they logged stays in this circle, and you can still tag them on an outing."
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
                guard await sync.removeMember(circleID: circleID, userID: membership.userID) else { return }
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
            guard succeeded else { return }
            guard let newID = store.startFreshCircleIdentity(),
                  let circle = store.activeCircle,
                  let personID = store.currentPerson?.id ?? store.circleMembers.first?.id else { return }
            await sync.activate(circleID: newID, name: circle.name, personID: personID)
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
    guard let personID = store.currentPerson?.id
            ?? store.circleMembers.first?.id
            ?? store.addCircleMember(name: "Me")?.id else {
        return "Add your name in Settings before joining a circle."
    }
    let previousCircleID = store.activeCircleID

    switch await sync.join(code, personID: personID) {
    case let .failed(message):
        return message
    case let .joined(circleID, circleName):
        if let previousCircleID, previousCircleID != circleID {
            await sync.discardAbandonedCircle(previousCircleID)
        }
        guard let adoptedPersonID = store.adoptCircle(id: circleID, name: circleName) else {
            return "This iPhone could not open the circle it just joined. Try syncing again."
        }
        guard let circle = store.activeCircle else { return nil }
        await sync.activate(circleID: circleID, name: circle.name, personID: adoptedPersonID)
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

    private var code: CircleJoinCode? { invitation?.code ?? CircleJoinCode(typedCode) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(invitation == nil ? "Join a circle" : "Invitation")
                        Text(invitation?.circleName ?? "Join a dining log").font(BBTheme.display(34))
                        Text("You will share one log. Everything on this iPhone goes with you, everything already in the circle comes back, and each person keeps their own reactions and rankings.")
                            .foregroundStyle(.secondary)
                    }
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
                        run {
                            error = await joinCircle(code: code, store: store, sync: sync)
                            if error == nil {
                                Haptics.success()
                                onJoined()
                                dismiss()
                            }
                        }
                    } label: {
                        if isWorking {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label(
                                sync.isSignedIn ? "Join This Circle" : "Sign In & Join",
                                systemImage: sync.isSignedIn ? "person.2.fill" : "apple.logo"
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
                }
                .padding(22)
                .readablePageWidth()
            }
            .editorialPage()
            .scrollDismissesKeyboard(.interactively)
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
