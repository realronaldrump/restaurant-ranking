import SwiftUI

@MainActor
struct MergeLocationsView: View {
    @Environment(AppStore.self) private var store
    @State private var keeperID: UUID?
    @State private var duplicateID: UUID?
    @State private var confirming = false

    var body: some View {
        Form {
            Section { Text("Choose the establishment record to keep, then the duplicate to fold into it. Every visit, dish, comparison reference, and Want to Try entry is reassigned.").foregroundStyle(.secondary) }
            Section("Keep this record") { Picker("Establishment", selection: $keeperID) { Text("Choose…").tag(UUID?.none); ForEach(store.locations) { Text($0.name).tag(UUID?.some($0.id)) } } }
            Section("Merge this duplicate") { Picker("Duplicate", selection: $duplicateID) { Text("Choose…").tag(UUID?.none); ForEach(store.locations.filter { $0.id != keeperID }) { Text($0.name).tag(UUID?.some($0.id)) } } }
            Section { Button("Merge Records", role: .destructive) { confirming = true }.disabled(keeperID == nil || duplicateID == nil || keeperID == duplicateID) }
        }
        .editorialForm().navigationTitle("Merge Duplicates").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Merge these establishments?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Merge", role: .destructive) { merge() }
        } message: { Text("The duplicate record will be removed after all of its history is moved. This can be undone only during the current editing session.") }
    }
    private func merge() { guard let keeper = store.locations.first(where: { $0.id == keeperID }), let duplicate = store.locations.first(where: { $0.id == duplicateID }) else { return }; store.merge(duplicate, into: keeper); keeperID = nil; duplicateID = nil; Haptics.success() }
}
