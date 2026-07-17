import CloudKit
import CoreLocation
import Photos
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @AppStorage("didCompleteGrandOpening") private var didCompleteGrandOpening = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @State private var accountStatus = "Checking…"
    @State private var newPerson = ""
    @State private var newCompanion = ""
    @State private var isShowingResetConfirmation = false

    var body: some View {
        Form {
            if store.circles.count > 1 {
                Section("Active ledger") {
                    Picker("Circle", selection: Binding(
                        get: { store.activeCircle?.id },
                        set: { if let id = $0 { store.activateCircle(id) } }
                    )) {
                        ForEach(store.circles) { circle in Text(circle.name).tag(UUID?.some(circle.id)) }
                    }
                    Text("Shared invitations can add another private ledger. Switching never mixes rankings between circles.").font(.caption).foregroundStyle(.secondary)
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
                ForEach(store.circleMembers) { person in HStack { Circle().fill(Color(hex: person.colorHex)).frame(width: 24, height: 24); Text(person.name); Spacer(); if person.id == store.currentPerson?.id { Text("This device").foregroundStyle(.secondary) } } }
                if store.circleMembers.count < 6 { HStack { TextField("Add a circle member", text: $newPerson); Button("Add") { _ = store.addPerson(name: newPerson); newPerson = "" }.disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty) } }
            }
            Section("Reusable companions") {
                ForEach(store.namedCompanions) { person in Label(person.name, systemImage: "person.crop.circle") }
                HStack {
                    TextField("Add a named companion", text: $newCompanion)
                    Button("Add") { _ = store.addNamedCompanion(name: newCompanion); newCompanion = "" }
                        .disabled(newCompanion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("iCloud & permissions") {
                LabeledContent("iCloud", value: accountStatus)
                LabeledContent("Foreground location", value: locationDescription)
                LabeledContent("Photo Library", value: photoDescription)
                Button("Open iOS Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            }
            Section("Experience") { Toggle("Subtle haptics", isOn: $hapticsEnabled) }
            Section("The score ladder") {
                ForEach(ScoreAnchor.ladder) { anchor in HStack(alignment: .firstTextBaseline) { Text(anchor.score.formatted(.number.precision(.fractionLength(0)))).font(BBTheme.score(24)).foregroundStyle(BBTheme.oxblood).frame(width: 38, alignment: .leading); Text(anchor.statement).font(.callout) } }
            }
            Section("Privacy") {
                Text("Records stay on your device and in your private or shared iCloud database. Map search uses Apple Maps, and photos are processed on device. The app has no ads or analytics.")
                NavigationLink("Read the full privacy policy") { PrivacyPolicyView() }
                Link("Privacy policy on the web", destination: URL(string: "https://realronaldrump.github.io/restaurant-ranking/privacy.html")!)
                Link("Support & privacy choices", destination: URL(string: "https://realronaldrump.github.io/restaurant-ranking/support.html")!)
            }
            Section("Start over") {
                Button("Reset App", role: .destructive) {
                    isShowingResetConfirmation = true
                }
                .accessibilityIdentifier("reset-app-button")
                Text("Erase every ledger and return to the beginning of onboarding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section { LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") }
        }
        .editorialForm()
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .task { do { accountStatus = try await CKContainer(identifier: PersistenceController.cloudContainerIdentifier).accountStatus().description } catch { accountStatus = "Unavailable" } }
        .alert("Reset Big Beautiful?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Erase Everything", role: .destructive) {
                guard store.eraseAllData() else { return }
                hapticsEnabled = true
                didCompleteGrandOpening = false
            }
        } message: {
            Text("This permanently deletes all circles, restaurants, visits, photos, rankings, and app setup from this device and iCloud. Shared-circle data may also be removed for other members. iOS permissions will not change. This cannot be undone.")
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
                Link("Read the complete policy and privacy choices", destination: URL(string: "https://realronaldrump.github.io/restaurant-ranking/privacy.html")!)
                    .font(.headline)
            }
            .padding(20)
            .readablePageWidth()
        }
        .editorialPage()
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
