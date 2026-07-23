import CloudKit
import CoreLocation
import Photos
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @AppStorage("didCompleteGrandOpening") private var didCompleteGrandOpening = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("didDismissPhotoVisitTimeSync") private var didDismissPhotoVisitTimeSync = false
    @State private var accountStatus = "Checking…"
    @State private var newPerson = ""
    @State private var newCompanion = ""
    @State private var editingPerson: PersonEntity?
    @State private var isShowingResetConfirmation = false
    @State private var isShowingRestoreConfirmation = false
    @State private var isPreparingBackup = false
    @State private var isRestoringBackup = false
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var backupDocument: AppBackupDocument?
    @State private var backupMessage: String?

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
            Section("iCloud & permissions") {
                LabeledContent("iCloud", value: accountStatus)
                LabeledContent("Foreground location", value: locationDescription)
                LabeledContent("Photo Library", value: photoDescription)
                Button("Open iOS Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Section("Experience") { Toggle("Subtle haptics", isOn: $hapticsEnabled) }
            Section("Backup & restore") {
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

                Text("A .bbrlog backup contains every circle, member, restaurant, visit, rating, comparison, wish-list entry, dish, and stored photo. Restore replaces the app’s current data. Backup files are not app-encrypted, and restored shared logs become private copies you can share again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let backupMessage {
                    Text(backupMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Text("Records stay on your device and in your private or shared iCloud database. Map search uses Apple Maps, and photos are processed on device. The app has no ads or analytics.")
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
            Section { LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") }
        }
        .editorialForm()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingPerson) { person in
            EditPersonView(person: person)
        }
        .task {
            guard store.persistence.isCloudSyncActive else {
                accountStatus = "Off"
                return
            }
            do {
                accountStatus = try await CKContainer(
                    identifier: PersistenceController.cloudContainerIdentifier
                ).accountStatus().description
            } catch {
                accountStatus = "Unavailable"
            }
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
        .confirmationDialog("Restore from backup?", isPresented: $isShowingRestoreConfirmation, titleVisibility: .visible) {
            Button("Choose Backup and Replace Everything", role: .destructive) {
                isImportingBackup = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected backup will replace all current dining logs and their iCloud-synced data. Export a current backup first if you may need it later.")
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
                    didDismissPhotoVisitTimeSync = false
                }
            }
        } message: {
            Text("This permanently deletes all circles, restaurants, visits, photos, rankings, and app setup from this device and iCloud. Shared-circle data may also be removed for other members. iOS permissions will not change. This cannot be undone.")
        }
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

private extension CKAccountStatus {
    var description: String { switch self { case .available: "Available"; case .noAccount: "No iCloud account"; case .restricted: "Restricted"; case .couldNotDetermine: "Could not determine"; case .temporarilyUnavailable: "Temporarily unavailable"; @unknown default: "Unknown" } }
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow("Effective July 16, 2026")
                Text("Private by design.").font(BBTheme.display(37))
                Text("Big Beautiful Restaurant Log does not collect, sell, or transmit personal data to the developer. There are no developer-operated servers, advertising SDKs, analytics SDKs, or third-party tracking systems.")
                Text("Dining records are stored on the device and, when iCloud is enabled, in your private or explicitly shared CloudKit databases. Map coordinates are sent to Apple only for ordinary MapKit searches. Photos are processed on-device; app-stored copies have embedded location metadata removed.")
                Text("Location is foreground-only and optional. Photo Library access is optional; the standard picker works without full-library permission. Permissions can be revoked at any time in iOS Settings.")
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
