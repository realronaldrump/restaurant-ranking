import CoreLocation
import Photos
import SwiftUI
import UniformTypeIdentifiers

private struct LiveRestoreEnrollment {
    let circleID: UUID
    let circleName: String
    let personID: UUID
    let personName: String
}

@MainActor
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @Environment(AppRouter.self) private var router
    @Environment(LocationService.self) private var locationService
    @AppStorage("didCompleteGrandOpening") private var didCompleteGrandOpening = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("didDismissPhotoVisitTimeSync") private var didDismissPhotoVisitTimeSync = false
    @AppStorage(AppearancePreference.storageKey) private var appearancePreference = AppearancePreference.system
    @State private var newCompanion = ""
    @State private var editingPerson: PersonEntity?
    @State private var isShowingResetConfirmation = false
    @State private var isShowingRestoreConfirmation = false
    @State private var isPreparingBackup = false
    @State private var isRestoringBackup = false
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var isImportingBeli = false
    @State private var beliSelection: BeliImportSelection?
    @State private var importToDelete: ExternalImportSessionEntity?
    @State private var backupDocument: AppBackupDocument?
    @State private var backupMessage: String?
    @State private var isConfirmingSyncAccountDeletion = false
    @State private var isDeletingSyncAccount = false
    @State private var isChangingCircleSync = false
    @State private var isResettingApp = false

    var body: some View {
        Form {
            if !didDismissPhotoVisitTimeSync, store.photoDateSyncCandidateCount > 0 {
                photoVisitTimeSuggestion
            }
            circleMembersSection
            namedCompanionsSection
            accountSyncSection
            permissionsSection
            experienceSection
            backupSection
            libraryUpkeepSection
            importedDataSection
            privacySection
            startOverSection
            versionSection
        }
        .editorialForm()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(store.activeCircleID?.uuidString ?? "none")-\(sync.isSignedIn)") {
            guard let circleID = store.activeCircleID, sync.isSignedIn else { return }
            await sync.refreshMembers(circleID: circleID)
        }
        .sheet(item: $editingPerson) { person in
            EditPersonView(person: person)
        }
        .fileExporter(
            isPresented: $isExportingBackup,
            document: backupDocument,
            contentType: .restaurantLogBackup,
            defaultFilename: backupFilename
        ) { result in
            switch result {
            case .success:
                backupMessage = "Full backup exported."
            case let .failure(error):
                backupMessage = error.localizedDescription
            }
            backupDocument = nil
        }
        .sheet(item: $beliSelection) { selection in
            BeliImportView(selection: selection) { summary in
                backupMessage = "Imported \(summary.outingsCreated) new outings and \(summary.photosAdded) photos from Beli."
            }
        }
        .editorialPrompt(item: $importToDelete) { session in
            EditorialPrompt.destructive(
                "Delete this Beli import from this iPhone?",
                message: "Deletes everything this import created, including edits you made inside those outings. Restaurants and outings that existed before the import are kept. If this log is shared, the deletions sync too. This cannot be undone.",
                actionTitle: "Delete imported data"
            ) {
                if let summary = store.deleteBeliImport(sessionID: session.id) {
                    backupMessage = deletionMessage(summary)
                    Haptics.success()
                } else {
                    backupMessage = "The Beli import could not be deleted."
                }
                importToDelete = nil
            }
        }
        .editorialPrompt(isPresented: $isShowingResetConfirmation) {
            EditorialPrompt.destructive(
                "Reset this iPhone and its synced circles?",
                message: "Erases every restaurant, outing, photo, and ranking on this iPhone. It also leaves circles you joined and deletes circles you own from the server. If the server cleanup fails, nothing is erased. This cannot be undone.",
                actionTitle: "Erase everything"
            ) {
                isResettingApp = true
                Task {
                    defer { isResettingApp = false }
                    if sync.isConfigured, sync.isSignedIn,
                       !(await sync.resetSyncedCircles()) {
                        backupMessage = sync.lastError
                        return
                    }
                    // Also clear local keys for stale circles that no longer
                    // have a server membership and therefore were absent from
                    // the retirement query.
                    for circle in store.circles { sync.forget(circleID: circle.id) }
                    guard store.eraseAllData() else { return }
                    didCompleteGrandOpening = false
                    hapticsEnabled = true
                    appearancePreference = .system
                    didDismissPhotoVisitTimeSync = false
                }
            }
        }
        .editorialPrompt(isPresented: $isConfirmingSyncAccountDeletion) {
            EditorialPrompt.destructive(
                "Delete your account and server data?",
                message: "Permanently deletes your account and everything stored on the server. Your log stays on this iPhone.",
                actionTitle: "Delete sync account"
            ) {
                isDeletingSyncAccount = true
                Task {
                    let deleted = await sync.deleteAccount()
                    backupMessage = deleted
                        ? "Your account and everything on the server were deleted. Your log is still on this iPhone."
                        : sync.lastError
                    isDeletingSyncAccount = false
                }
            }
        }
        .editorialPrompt(isPresented: $isShowingRestoreConfirmation) {
            EditorialPrompt.destructive(
                "Restore from backup?",
                message: "The backup replaces the log on this iPhone, and if you share a circle, it replaces the shared copy for everyone. Export a backup first if you might want the current log back.",
                actionTitle: "Choose backup and replace everything"
            ) {
                isImportingBackup = true
            }
        }
    }

    private var circleMembersSection: some View {
        Section {
            ForEach(store.circleMembers) { person in
                Button { editingPerson = person } label: {
                    HStack {
                        Circle().fill(Color(hex: person.colorHex)).frame(width: 24, height: 24)
                        Text(person.name).foregroundStyle(BBTheme.ink)
                        Spacer()
                        if person.id == store.currentPerson?.id {
                            Text("You").foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Eyebrow("Circle")
        } footer: {
            Text(circleRosterExplanation)
        }
        .listRowBackground(BBTheme.surface)
    }

    private var namedCompanionsSection: some View {
        Section {
            ForEach(store.namedCompanions) { person in
                Button { editingPerson = person } label: {
                    HStack {
                        Label(person.name, systemImage: "person.crop.circle").foregroundStyle(BBTheme.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                TextField("Add someone you dine with", text: $newCompanion)
                Button("Add") {
                    _ = store.addNamedCompanion(name: newCompanion)
                    newCompanion = ""
                }
                .disabled(newCompanion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Eyebrow("People you dine with")
        } footer: {
            Text("Names you can add to an outing. They do not need the app, and adding someone never shares your log.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var accountSyncSection: some View {
        Section {
            LabeledContent("Sync", value: syncDescription)
            if sync.isConfigured {
                Text(syncExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if sync.isSignedIn {
                    Button("Manage people and sharing") {
                        router.sheet = .circle
                    }
                } else {
                    Button { signIn() } label: {
                        if isChangingCircleSync {
                            HStack { ProgressView(); Text("Signing in…") }
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Sign in with Apple", systemImage: "apple.logo")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isChangingCircleSync)
                }
            }
            syncStatusMessage
            if sync.isConfigured, sync.isSignedIn {
                Button("Sign out") { Task { await sync.signOut() } }
                Button("Delete account and server data", role: .destructive) {
                    isConfirmingSyncAccountDeletion = true
                }
                .disabled(isDeletingSyncAccount)
            }
        } header: {
            Eyebrow("Account and sync")
        }
        .listRowBackground(BBTheme.surface)
    }

    @ViewBuilder
    private var syncStatusMessage: some View {
        switch sync.status {
        case .offline:
            Text("Saved on this iPhone. They will upload when you are back online.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(BBTheme.oxblood)
        default:
            EmptyView()
        }
    }

    private var permissionsSection: some View {
        Section {
            LabeledContent("Foreground location", value: locationDescription)
            LabeledContent("Photo Library", value: photoDescription)
            Button("Open iOS Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        } header: {
            Eyebrow("iOS permissions")
        } footer: {
            Text("Both are optional. Changing them here does not affect anything already in your log.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var experienceSection: some View {
        Section {
            Picker("Appearance", selection: $appearancePreference) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance-picker")
            Toggle("Subtle haptics", isOn: $hapticsEnabled)
        } header: {
            Eyebrow("Appearance")
        } footer: {
            Text("System matches your iPhone’s appearance setting.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var backupSection: some View {
        Section {
            Button { isImportingBeli = true } label: {
                Label("Import from Beli", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(isPreparingBackup || isRestoringBackup)
            .fileImporter(isPresented: $isImportingBeli, allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result { beliSelection = .init(url: url) }
                else if case .failure(let error) = result { backupMessage = error.localizedDescription }
            }

            Button { prepareBackup() } label: {
                Label(isPreparingBackup ? "Preparing backup…" : "Export full backup", systemImage: "square.and.arrow.up")
            }
            .disabled(isPreparingBackup || isRestoringBackup)

            Button { isShowingRestoreConfirmation = true } label: {
                Label(isRestoringBackup ? "Restoring backup…" : "Restore from backup", systemImage: "arrow.down.doc")
            }
            .disabled(isPreparingBackup || isRestoringBackup)
            .accessibilityIdentifier("restore-backup-button")
            .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.restaurantLogBackup]) { result in
                restoreBackup(result)
            }

            Text("Importing the same Beli export twice updates your outings instead of duplicating them. A backup file holds everything: restaurants, outings, reactions, comparisons, dishes, photos, and your Want to Try list.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let backupMessage {
                Text(backupMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Eyebrow("Backups and imports")
        } footer: {
            Text("Backups are created on this iPhone. If you share a circle, imports and restores also change what everyone else sees.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var libraryUpkeepSection: some View {
        Section {
            Button { router.morePath.append(.merge) } label: {
                HStack {
                    Label("Merge duplicates", systemImage: "arrow.triangle.merge")
                    Spacer()
                    Text(duplicateSuggestionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("merge-duplicates-button")
            .accessibilityLabel("Merge duplicates. \(duplicateSuggestionSummary).")
        } header: {
            Eyebrow("Library upkeep")
        } footer: {
            Text("Restaurants with a matching Maps listing, address, or coordinate are merged automatically. This is for the ones only you can judge.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var duplicateSuggestionSummary: String {
        let count = store.duplicateLocationSuggestions().count
        switch count {
        case 0: return "None found"
        case 1: return "1 to review"
        default: return "\(count) to review"
        }
    }

    @ViewBuilder
    private var importedDataSection: some View {
        if !store.beliImportSessions.isEmpty {
            Section {
                ForEach(store.beliImportSessions) { session in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Beli import").font(.headline)
                                Text(session.importedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete imported data", role: .destructive) { importToDelete = session }
                        }
                        Text(importSummary(session))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Eyebrow("Imported data")
            } footer: {
                Text("Deleting an import only removes what that import created. Anything that existed beforehand is kept.")
            }
            .listRowBackground(BBTheme.surface)
        }
    }

    private var privacySection: some View {
        Section {
            Text("Your log is encrypted on this iPhone before it is uploaded, and the key never leaves your devices, so the server stores something it cannot read. Map search uses Apple Maps. No ads, no analytics, no tracking.")
            NavigationLink("Read the full privacy policy") { PrivacyPolicyView() }
            if let privacyURL = URL(string: "https://realronaldrump.github.io/restaurant-ranking/privacy.html") {
                Link("Privacy policy on the web", destination: privacyURL)
            }
            if let supportURL = URL(string: "https://realronaldrump.github.io/restaurant-ranking/support.html") {
                Link("Support and privacy choices", destination: supportURL)
            }
        } header: {
            Eyebrow("Privacy")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var startOverSection: some View {
        Section {
            Button(role: .destructive) {
                isShowingResetConfirmation = true
            } label: {
                if isResettingApp {
                    HStack { ProgressView(); Text("Resetting…") }
                } else {
                    Text("Reset app")
                }
            }
            .disabled(isResettingApp)
            .accessibilityIdentifier("reset-app-button")
            Text("Erase this iPhone’s log and start over. Also leaves circles you joined and deletes circles you own from the server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Eyebrow("Reset")
        }
        .listRowBackground(BBTheme.surface)
    }

    private var versionSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)
            LabeledContent("Build", value: buildNumber)
            LabeledContent("Release date", value: Self.releaseDateText)
        } footer: {
            Text("Big Beautiful Restaurant Log \(appVersion) (build \(buildNumber)) • Released \(Self.releaseDateText)")
                .accessibilityIdentifier("app-version-footer")
        }
        .listRowBackground(BBTheme.surface)
    }

    private static let releaseDateText = "August 3, 2026"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    private var photoVisitTimeSuggestion: some View {
        let count = store.photoDateSyncCandidateCount
        return Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync outings with photo time").font(.headline)
                    Text("Set \(count) \(count == 1 ? "outing" : "outings") to the time its earliest photo was taken.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(BBTheme.oxblood)
            }
            Button {
                let updated = store.syncVisitDatesWithStoredPhotoTimes()
                if updated > 0 { Haptics.success() }
            } label: {
                Label("Sync \(count) outing \(count == 1 ? "date" : "dates")", systemImage: "checkmark.circle")
            }
            Button("Not now") { didDismissPhotoVisitTimeSync = true }
                .foregroundStyle(.secondary)
        } header: {
            Eyebrow("Suggestion")
        } footer: {
            Text("Uses the dates already saved with your attached photos. Your photo library is not opened.")
        }
        .listRowBackground(BBTheme.surface)
    }

    private func importSummary(_ session: ExternalImportSessionEntity) -> String {
        var parts: [String] = []
        if session.restaurantsCreated > 0 { parts.append("\(session.restaurantsCreated) restaurants") }
        if session.outingsCreated > 0 { parts.append("\(session.outingsCreated) outings") }
        if session.photosAdded > 0 { parts.append("\(session.photosAdded) photos") }
        if session.dishesAdded > 0 { parts.append("\(session.dishesAdded) dishes") }
        if session.rankingsSeeded > 0 { parts.append("\(session.rankingsSeeded) starting ranks") }
        return parts.isEmpty ? "Matched what was already here" : parts.joined(separator: " · ")
    }

    private func deletionMessage(_ summary: BeliImportDeletionSummary) -> String {
        var message = "Deleted \(summary.outingsDeleted) outings, \(summary.photosDeleted) photos, \(summary.dishesDeleted) dishes, and \(summary.rankingsDeleted) starting ranks from the Beli import."
        if summary.restaurantsDeleted > 0 { message += " Deleted \(summary.restaurantsDeleted) imported restaurants." }
        if summary.restaurantsPreserved > 0 { message += " Preserved \(summary.restaurantsPreserved) restaurants with other activity." }
        return message
    }

    private var backupFilename: String {
        "Big Beautiful Backup \(Self.backupDateFormatter.string(from: .now))"
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func prepareBackup() {
        isPreparingBackup = true
        backupMessage = nil
        Task {
            defer { isPreparingBackup = false }
            do {
                let archive = try await AppBackupService.makeArchive(from: store)
                let data = try await Task.detached(priority: .userInitiated) {
                    try AppBackupCodec.encode(archive)
                }.value
                backupDocument = AppBackupDocument(data: data)
                isExportingBackup = true
            } catch {
                backupMessage = error.localizedDescription
            }
        }
    }

    private func restoreBackup(_ result: Result<URL, Error>) {
        isRestoringBackup = true
        backupMessage = nil
        Task {
            defer { isRestoringBackup = false }
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let archive = try await Task.detached(priority: .userInitiated) {
                    let data = try AppBackupCodec.readBackupData(from: url)
                    return try AppBackupCodec.decode(data)
                }.value

                var liveEnrollment: LiveRestoreEnrollment?
                if sync.isConfigured, sync.isSignedIn, let circle = store.activeCircle,
                   let membership = try await sync.authenticatedMembership(circleID: circle.id) {
                    guard sync.hasKey(circleID: circle.id) else { throw SyncError.circleKeyMissing }
                    liveEnrollment = .init(
                        circleID: circle.id,
                        circleName: circle.name,
                        personID: membership.personID,
                        personName: store.person(id: membership.personID)?.name
                            ?? store.currentPerson?.name
                            ?? "Me"
                    )
                    await sync.prepareForBackupRestore(circleID: circle.id)
                }

                // AppBackup replaces the whole Core Data graph. Suppress the
                // ordinary save hook until the restored graph has been attached
                // to the authenticated circle; otherwise old circle IDs can be
                // scheduled as accidental mass deletions.
                let commitHandler = store.didCommit
                store.didCommit = nil
                defer { store.didCommit = commitHandler }
                let summary = try await AppBackupService.restore(archive, into: store)
                if let liveEnrollment {
                    guard store.reconnectRestoredLog(
                        to: liveEnrollment.circleID,
                        circleName: liveEnrollment.circleName,
                        memberPersonID: liveEnrollment.personID,
                        fallbackPersonName: liveEnrollment.personName
                    ) else {
                        backupMessage = store.lastError ?? "The backup was restored on this iPhone but could not reconnect to your circle. Nothing on the server changed."
                        return
                    }
                }

                if sync.isConfigured, sync.isSignedIn,
                   let circle = store.activeCircle,
                   let personID = store.currentPerson?.id {
                    let activation = await sync.activate(
                        circleID: circle.id,
                        name: circle.name,
                        personID: personID
                    )
                    guard case let .ready(serverPersonID) = activation,
                          serverPersonID == personID else {
                        backupMessage = "The backup was restored on this iPhone, but syncing stopped. \(sync.lastError ?? "Try the backup import again.")"
                        return
                    }
                }
                hapticsEnabled = archive.preferences.hapticsEnabled
                didCompleteGrandOpening = !store.circles.isEmpty
                didDismissPhotoVisitTimeSync = false
                backupMessage = "Restored \(summary.visits) outings across \(summary.circles) circle\(summary.circles == 1 ? "" : "s")."
                Haptics.success()
            } catch {
                backupMessage = error.localizedDescription
            }
        }
    }

    private var locationDescription: String {
        switch locationService.authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            locationService.accuracyAuthorization == .fullAccuracy ? "Allowed · Precise" : "Allowed · Approximate"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
    private var photoDescription: String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) { case .authorized: "Full access"; case .limited: "Limited"; case .denied: "Denied"; case .restricted: "Restricted"; case .notDetermined: "Not requested"; @unknown default: "Unknown" }
    }
    private var syncDescription: String {
        guard sync.isConfigured else { return "Not available in this build" }
        guard sync.isSignedIn else { return "Only this iPhone has a copy" }
        if sync.isPreparing || sync.status.isBusy { return "Syncing…" }
        let count = sync.members.count
        return count > 1
            ? "\(count) people synced"
            : "Backed up and encrypted"
    }

    private var syncExplanation: String {
        guard sync.isSignedIn else {
            return "This circle has \(store.circleMembers.count) \(store.circleMembers.count == 1 ? "person" : "people") in it but exists only on this iPhone. Sign in to back it up and share it."
        }
        return sync.members.count > 1
            ? "You share the same restaurants and outings. Everyone keeps their own reactions and rankings."
            : "Your log is backed up and encrypted. Nobody else has their own copy yet."
    }

    private var circleRosterExplanation: String {
        let count = store.circleMembers.count
        if count > 1 {
            return "\(count) people keep their own reactions in this log. That does not mean they have their own copy — set that up under Account and sync."
        }
        return "Just you so far. Set up sharing under Account and sync to give someone their own copy."
    }

    private func signIn() {
        isChangingCircleSync = true
        Task {
            defer { isChangingCircleSync = false }
            guard await sync.signInWithApple(),
                  let circle = store.activeCircle,
                  let personID = store.currentPerson?.id else {
                backupMessage = sync.lastError ?? SyncError.deviceIdentityMissing.localizedDescription
                return
            }
            if case .failed = await sync.activate(circleID: circle.id, name: circle.name, personID: personID) {
                backupMessage = sync.lastError
            }
        }
    }

}

@MainActor
private struct EditPersonView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let person: PersonEntity
    @State private var name: String
    @State private var errorMessage: String?
    @State private var isConfirmingDeletion = false

    init(person: PersonEntity) {
        self.person = person
        _name = State(initialValue: person.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(BBTheme.oxblood)
                    }
                } header: { Eyebrow("Name") }
                .listRowBackground(BBTheme.surface)
                if !person.isCircleMember {
                    Section {
                        Button("Delete person", role: .destructive) {
                            isConfirmingDeletion = true
                        }
                    } footer: {
                        Text("Removes them from the list. Past outings keep their name and reactions.")
                    }
                    .listRowBackground(BBTheme.surface)
                }
            }
            .editorialForm()
            .navigationTitle(person.isCircleMember ? "Edit Circle Member" : "Edit Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if saveName() { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .editorialPrompt(isPresented: $isConfirmingDeletion) {
                EditorialPrompt.destructive(
                    "Delete \(person.name)?",
                    message: "They will no longer appear when you add people to an outing. Past outings are unchanged.",
                    actionTitle: "Delete person"
                ) {
                    if store.deleteNamedCompanion(person.id) { dismiss() }
                }
            }
        }
    }

    @discardableResult
    private func saveName() -> Bool {
        guard store.renamePerson(person, to: name) else {
            errorMessage = "Each person needs a different name."
            return false
        }
        errorMessage = nil
        return true
    }
}


struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow("Effective August 1, 2026")
                Text("Private by design.").font(BBTheme.display(37))
                Text("This app has no advertising, analytics, data broker, or tracking SDK. Your log is kept in your account through Sign in with Apple and a Supabase service run by the developer, and it is encrypted on this iPhone before anything is uploaded.")
                Text("When syncing is on, names, outings, notes, and photos are encrypted on this iPhone before upload. The service stores that encrypted data against your Apple account and a device identifier the app generates. It never receives your key, so it cannot read any of it. It does keep the email address Apple provides for sign-in.")
                Text("Map searches go to Apple through MapKit. Coordinates you save may be included in encrypted sync records, which the service cannot read. Photos are processed on this device, and saved copies have their location data removed before upload.")
                Text("A Beli export is read on this device. The app uses Apple Maps to match restaurants and downloads only the photo links in that export, and only once you start the import. Beli profile, social, device, follow, and comment data is discarded.")
                Text("Location is optional and only used while the app is open. Photo Library access is optional too — the standard picker works without it. You can revoke either one in iOS Settings.")
                Text("From Settings you can sign out, remove someone from your circle, leave a circle, or delete your account and everything stored on the server. None of these quietly delete the log on this iPhone.")
                if let privacyURL = URL(string: "https://realronaldrump.github.io/restaurant-ranking/privacy.html") {
                    Link("Read the complete policy and privacy choices", destination: privacyURL)
                        .font(.headline)
                }
            }
            .padding(20)
            .readablePageWidth()
        }
        .editorialPage()
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
