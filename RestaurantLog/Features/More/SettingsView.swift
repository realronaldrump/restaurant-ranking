import CoreLocation
import Photos
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @Environment(LocationService.self) private var locationService
    @AppStorage("didCompleteGrandOpening") private var didCompleteGrandOpening = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("didDismissPhotoVisitTimeSync") private var didDismissPhotoVisitTimeSync = false
    @AppStorage(AppearancePreference.storageKey) private var appearancePreference = AppearancePreference.system
    @State private var newPerson = ""
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

    var body: some View {
        Form {
            if !didDismissPhotoVisitTimeSync, store.photoDateSyncCandidateCount > 0 {
                photoVisitTimeSuggestion
            }
            if store.circles.count > 1 {
                Section("Active log") {
                    Picker("Circle", selection: Binding(
                        get: { store.activeCircle?.id },
                        set: { if let id = $0 { store.activateCircle(id) } }
                    )) {
                        ForEach(store.circles) { circle in Text(circle.name).tag(UUID?.some(circle.id)) }
                    }
                    Text("Shared invitations can add another private log. Switching never mixes rankings between circles.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Circle") {
                if !store.circleMembers.isEmpty {
                    Picker("This device is used by", selection: Binding(
                        get: { store.currentPerson?.id },
                        set: { if let id = $0 { store.selectCurrentPerson(id) } }
                    )) {
                        ForEach(store.circleMembers) { person in Text(person.name).tag(UUID?.some(person.id)) }
                    }
                }
                ForEach(store.circleMembers) { person in
                    Button { editingPerson = person } label: {
                        HStack {
                            Circle().fill(Color(hex: person.colorHex)).frame(width: 24, height: 24)
                            Text(person.name).foregroundStyle(BBTheme.ink)
                            Spacer()
                            if person.id == store.currentPerson?.id { Text("This device").foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if store.circleMembers.count < 6 {
                    HStack {
                        TextField("Add a circle member", text: $newPerson)
                        Button("Add") { _ = store.addCircleMember(name: newPerson); newPerson = "" }
                            .disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
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
                    Button("Add") { _ = store.addNamedCompanion(name: newCompanion); newCompanion = "" }
                        .disabled(newCompanion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Other people")
            } footer: {
                Text("These names can be reused on visits. Add one to the circle later without losing any linked history.")
            }
            Section("Syncing & permissions") {
                LabeledContent("Circle sync", value: syncDescription)
                if case .offline = sync.status {
                    Text("Your latest changes are saved on this iPhone and will upload when the connection returns.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case let .failed(message) = sync.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(BBTheme.oxblood)
                }
                if sync.isConfigured {
                    if sync.isSignedIn {
                        if let circleID = store.activeCircleID, sync.isSyncing(circleID: circleID) {
                            Button("Turn Off Syncing for This Circle") {
                                sync.disableSync(circleID: circleID)
                            }
                        }
                        Button("Sign Out") { Task { await sync.signOut() } }
                        Button("Delete Sync Account and Service Data", role: .destructive) {
                            isConfirmingSyncAccountDeletion = true
                        }
                        .disabled(isDeletingSyncAccount)
                    } else {
                        Button("Sign in with Apple") { Task { await sync.signInWithApple() } }
                    }
                }
                LabeledContent("Foreground location", value: locationDescription)
                LabeledContent("Photo Library", value: photoDescription)
                Button("Open iOS Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
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
                Text("Experience")
            } footer: {
                Text("System follows your iPhone’s appearance setting.")
            }
            Section("Backup & restore") {
                Button { isImportingBeli = true } label: {
                    Label("Import from Beli", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(isPreparingBackup || isRestoringBackup)

                Button {
                    prepareBackup()
                } label: {
                    Label(isPreparingBackup ? "Preparing Backup…" : "Export Full Backup", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparingBackup || isRestoringBackup)

                Button {
                    isShowingRestoreConfirmation = true
                } label: {
                    Label(isRestoringBackup ? "Restoring Backup…" : "Restore from Backup", systemImage: "arrow.down.doc")
                }
                .disabled(isPreparingBackup || isRestoringBackup)

                Text("Beli ZIP imports add or update dining history without duplicating previous imports. A .bbrlog backup contains every circle, member, restaurant, visit, rating, comparison, wish-list entry, dish, stored photo, and import link. Restore replaces the app’s current data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let backupMessage {
                    Text(backupMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
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
                                Button("Delete", role: .destructive) { importToDelete = session }
                            }
                            Text(importSummary(session))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("Imported data")
                } footer: {
                    Text("Deleting an import removes the outings, photos, dishes, and ranking seeds it created. Restaurants or outings that existed before the import are preserved.")
                }
            }
            Section("Privacy") {
                Text("The app works locally without an account. With circle syncing on, Sign in with Apple identifiers and encrypted content are stored by the sync service; the circle key never leaves member devices, so the service cannot read dining records or photos. Map search uses Apple Maps. There are no ads, analytics, or tracking.")
                NavigationLink("Read the full privacy policy") { PrivacyPolicyView() }
                if let privacyURL = URL(string: "https://realronaldrump.github.io/restaurant-ranking/privacy.html") {
                    Link("Privacy policy on the web", destination: privacyURL)
                }
                if let supportURL = URL(string: "https://realronaldrump.github.io/restaurant-ranking/support.html") {
                    Link("Support & privacy choices", destination: supportURL)
                }
            }
            Section("Start over") {
                Button("Reset App", role: .destructive) {
                    isShowingResetConfirmation = true
                }
                .accessibilityIdentifier("reset-app-button")
                Text("Erase every dining log and return to the beginning of onboarding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Release date", value: Self.releaseDateText)
            } footer: {
                Text("Big Beautiful Restaurant Log \(appVersion) • Released \(Self.releaseDateText)")
                    .accessibilityIdentifier("app-version-footer")
            }
        }
        .editorialForm()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
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
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.restaurantLogBackup]) { result in
            restoreBackup(result)
        }
        .fileImporter(isPresented: $isImportingBeli, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { beliSelection = .init(url: url) }
            else if case .failure(let error) = result { backupMessage = error.localizedDescription }
        }
        .sheet(item: $beliSelection) { selection in
            BeliImportView(selection: selection) { summary in
                backupMessage = "Imported \(summary.outingsCreated) new outings and \(summary.photosAdded) photos from Beli."
            }
        }
        .alert("Delete this Beli import?", isPresented: deletionAlertPresented, presenting: importToDelete) { session in
            Button("Delete Imported Data", role: .destructive) {
                if let summary = store.deleteBeliImport(sessionID: session.id) {
                    backupMessage = deletionMessage(summary)
                    Haptics.success()
                } else {
                    backupMessage = "The Beli import could not be deleted."
                }
                importToDelete = nil
            }
            Button("Cancel", role: .cancel) { importToDelete = nil }
        } message: { _ in
            Text("This permanently removes the data created by this import, including any edits made inside its imported outings. Pre-existing matched records remain. This cannot be undone.")
        }
        .confirmationDialog("Restore from backup?", isPresented: $isShowingRestoreConfirmation, titleVisibility: .visible) {
            Button("Choose Backup and Replace Everything", role: .destructive) {
                isImportingBackup = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected backup will replace all current dining logs on this iPhone, and the replacement will then sync to the rest of your circle. Export a current backup first if you may need it later.")
        }
        .alert("Reset Big Beautiful?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Erase Everything", role: .destructive) {
                didCompleteGrandOpening = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard store.eraseAllData() else {
                        didCompleteGrandOpening = true
                        return
                    }
                    hapticsEnabled = true
                    appearancePreference = .system
                    didDismissPhotoVisitTimeSync = false
                }
            }
        } message: {
            Text("This permanently deletes all circles, restaurants, visits, photos, rankings, and app setup from this iPhone. If the circle is synced, the deletions are published to the other members as well. iOS permissions will not change. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete your sync account and service data?",
            isPresented: $isConfirmingSyncAccountDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Sync Account", role: .destructive) {
                isDeletingSyncAccount = true
                Task {
                    let deleted = await sync.deleteSyncAccount()
                    backupMessage = deleted
                        ? "Your sync account and its service data were deleted. Your on-device dining logs were preserved."
                        : sync.lastError
                    isDeletingSyncAccount = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Owned circles, encrypted records, stored photo objects, invitations, memberships, and the service account are permanently deleted. Circles owned by someone else are left for their remaining members. Dining logs already on this iPhone stay here with syncing off.")
        }
    }

    private static let releaseDateText = "July 28, 2026"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var photoVisitTimeSuggestion: some View {
        let count = store.photoDateSyncCandidateCount
        return Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync visits with photo time").font(.headline)
                    Text("Use the earliest verified photo capture time for \(count) previous \(count == 1 ? "visit" : "visits") across your logs.")
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
                Label("Sync \(count) Visit \(count == 1 ? "Time" : "Times")", systemImage: "checkmark.circle")
            }
            Button("Not Now") { didDismissPhotoVisitTimeSync = true }
                .foregroundStyle(.secondary)
        } header: {
            Text("Suggestion")
        } footer: {
            Text("This uses verified capture metadata already saved with your attached photos and does not access your photo library.")
        }
    }

    private var deletionAlertPresented: Binding<Bool> {
        Binding(
            get: { importToDelete != nil },
            set: { if !$0 { importToDelete = nil } }
        )
    }

    private func importSummary(_ session: ExternalImportSessionEntity) -> String {
        var parts: [String] = []
        if session.restaurantsCreated > 0 { parts.append("\(session.restaurantsCreated) restaurants") }
        if session.outingsCreated > 0 { parts.append("\(session.outingsCreated) outings") }
        if session.photosAdded > 0 { parts.append("\(session.photosAdded) photos") }
        if session.dishesAdded > 0 { parts.append("\(session.dishesAdded) dishes") }
        if session.rankingsSeeded > 0 { parts.append("\(session.rankingsSeeded) ranking seeds") }
        return parts.isEmpty ? "Matched existing dining records" : parts.joined(separator: " · ")
    }

    private func deletionMessage(_ summary: BeliImportDeletionSummary) -> String {
        var message = "Deleted \(summary.outingsDeleted) outings, \(summary.photosDeleted) photos, \(summary.dishesDeleted) dishes, and \(summary.rankingsDeleted) ranking seeds from the Beli import."
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
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return try AppBackupCodec.decode(data)
                }.value
                let summary = try await AppBackupService.restore(archive, into: store)
                hapticsEnabled = archive.preferences.hapticsEnabled
                didCompleteGrandOpening = !store.circles.isEmpty
                didDismissPhotoVisitTimeSync = false
                backupMessage = "Restored \(summary.visits) visits across \(summary.circles) circle\(summary.circles == 1 ? "" : "s")."
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
        guard sync.isSignedIn else { return "Signed out" }
        guard let circleID = store.activeCircleID, sync.isSyncing(circleID: circleID) else { return "Off for this circle" }
        return sync.status.description
    }
}

@MainActor
private struct EditPersonView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let person: PersonEntity
    @State private var name: String
    @State private var errorMessage: String?

    init(person: PersonEntity) {
        self.person = person
        _name = State(initialValue: person.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(BBTheme.oxblood)
                    }
                }
                if !person.isCircleMember, store.circleMembers.count < 6 {
                    Section {
                        Button("Add to Circle") {
                            guard saveName(), store.addCircleMember(name: person.name) != nil else { return }
                            dismiss()
                        }
                    } footer: {
                        Text("Existing visit tags stay attached, and this person can identify themselves and add ratings on a shared device.")
                    }
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
        }
    }

    @discardableResult
    private func saveName() -> Bool {
        guard store.renamePerson(person, to: name) else {
            errorMessage = "Use a distinct name for each person in this circle."
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
                Eyebrow("Effective July 29, 2026")
                Text("Private by design.").font(BBTheme.display(37))
                Text("Big Beautiful Restaurant Log has no advertising, analytics, data broker, or tracking SDK. The app works locally without an account. Optional circle syncing uses a developer-operated Supabase service and Sign in with Apple.")
                Text("When syncing is on, member names, dining records, notes, and photos are encrypted on this iPhone before upload. The service stores ciphertext linked to a Sign in with Apple account and an app-generated device identifier, but never receives the circle key and cannot read the dining content. The service retains the account email Apple provides for authentication.")
                Text("Map searches are sent to Apple through MapKit. Coordinates saved in the dining log may be included in encrypted sync records; the sync service cannot read them. Photos are processed on-device, and app-stored copies have embedded location metadata removed before encrypted upload.")
                Text("If you import a Beli export, the ZIP is read on-device. The app contacts Apple Maps to help match restaurants and downloads only the Beli photo links included in that export when you explicitly start the import. Beli profile, social, device, follow, and comment data is not retained.")
                Text("Location is foreground-only and optional. Photo Library access is optional; the standard picker works without full-library permission. Permissions can be revoked at any time in iOS Settings.")
                Text("Settings lets you turn syncing off, sign out, remove a member, delete an owned circle’s encrypted service copy and photos, or delete the sync account and all service data it owns. These actions do not silently delete the on-device dining log.")
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
