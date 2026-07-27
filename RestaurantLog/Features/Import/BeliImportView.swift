import SwiftUI

struct BeliImportSelection: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
struct BeliImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService

    let selection: BeliImportSelection
    var onComplete: ((BeliImportSummary) -> Void)?

    @State private var archive: BeliParsedArchive?
    @State private var candidates: [String: [PlaceCandidate]] = [:]
    @State private var resolutions: [String: BeliLocationResolution] = [:]
    @State private var photoAssignments: [String: String] = [:]
    @State private var dishAssignments: [String: String] = [:]
    @State private var status: Status = .loading("Reading Beli export…")

    private enum Status: Equatable {
        case loading(String)
        case review
        case importing(String)
        case complete(BeliImportSummary)
        case failed(String)

        var isBusy: Bool {
            switch self { case .loading, .importing: true; default: false }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .loading(let message), .importing(let message): progress(message)
                case .review: reviewForm
                case .complete(let summary): completion(summary)
                case .failed(let message): failure(message)
                }
            }
            .navigationTitle("Import from Beli")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(status.isBusy ? "Cancel" : "Close") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(status.isBusy)
        .task { await prepare() }
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(BBTheme.oxblood)
            Text(message).font(.headline).multilineTextAlignment(.center)
            Text("The export stays on this device. Restaurant matching uses Apple Maps, and photo URLs are downloaded directly from Beli.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
    }

    private var reviewForm: some View {
        Form {
            if let archive {
                Section("Import preview") {
                    LabeledContent("Ranked restaurants", value: "\(archive.rankings.count)")
                    LabeledContent("Known outing dates", value: "\(archive.knownVisitCount)")
                    LabeledContent("Date unknown", value: "\(archive.unknownVisitCount)")
                    LabeledContent("Photos", value: "\(archive.photos.count)")
                    Text("Beli's rank will seed the initial order. Future ratings and comparisons can change it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(archive.rankings) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("#\(row.rank) · \(row.restaurantName)").font(.headline)
                                Spacer()
                                if row.visitDates.isEmpty {
                                    Text("DATE UNKNOWN").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                                }
                            }
                            Text(row.city).font(.caption).foregroundStyle(.secondary)
                            Picker("Restaurant match", selection: resolutionBinding(for: row)) {
                                ForEach(options(for: row)) { option in Text(option.title).tag(option.resolution) }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Restaurant match for \(row.restaurantName)")
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Review restaurant matches")
                } footer: {
                    Text("Choose separate locations for branches in the same city, or assign several Beli rows to the same existing/Maps restaurant to merge them.")
                }

                if !ambiguousPhotos.isEmpty {
                    Section("Assign ambiguous photos") {
                        ForEach(ambiguousPhotos) { photo in
                            Picker(photo.caption ?? photo.restaurantName, selection: photoAssignmentBinding(photo)) {
                                ForEach(matchingRankings(name: photo.restaurantName, city: photo.city)) { row in
                                    Text("#\(row.rank) · \(row.restaurantName)").tag(row.id)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await importArchive(archive) }
                    } label: {
                        Label("Download Photos and Import", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(resolutions.values.allSatisfy { $0 == .skip })
                } footer: {
                    Text("Importing again is safe: existing Beli records are linked or updated instead of duplicated. Failed photo downloads can be retried by importing the ZIP again.")
                }
            }
        }
        .editorialForm()
    }

    private func completion(_ summary: BeliImportSummary) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 52)).foregroundStyle(BBTheme.sage)
                Text("Beli history imported").font(BBTheme.display(32)).multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    resultRow("Restaurants created", summary.restaurantsCreated)
                    resultRow("Restaurants linked", summary.restaurantsLinked)
                    resultRow("Outings created", summary.outingsCreated)
                    resultRow("Existing outings linked", summary.outingsLinked)
                    resultRow("Photos added", summary.photosAdded)
                    resultRow("Favorite dishes added", summary.dishesAdded)
                    resultRow("Rankings seeded", summary.rankingsSeeded)
                    if summary.failedPhotos > 0 { resultRow("Photos to retry", summary.failedPhotos) }
                    if summary.skippedRows > 0 { resultRow("Rows skipped", summary.skippedRows) }
                }
                .editorialCard()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(24).readablePageWidth()
        }
        .editorialPage()
    }

    private func resultRow(_ title: String, _ value: Int) -> some View {
        HStack { Text(title); Spacer(); Text("\(value)").font(.body.monospacedDigit().weight(.semibold)) }
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't import this export", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await prepare() } }.buttonStyle(.borderedProminent)
        }
    }

    private func prepare() async {
        status = .loading("Reading Beli export…")
        let url = selection.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let parsed = try await Task.detached(priority: .userInitiated) { try BeliImporter.parse(url: url) }.value
            try Task.checkCancellation()
            archive = parsed
            status = .loading("Matching restaurants with Apple Maps…")
            await resolve(parsed)
            status = .review
        } catch is CancellationError {
            dismiss()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func resolve(_ archive: BeliParsedArchive) async {
        let duplicateGroups = Dictionary(grouping: archive.rankings) { identity(name: $0.restaurantName, city: $0.city) }
        for (index, row) in archive.rankings.enumerated() {
            if Task.isCancelled { return }
            status = .loading("Matching restaurant \(index + 1) of \(archive.rankings.count)…")
            let existing = store.locations.filter {
                BeliImporter.normalize($0.name) == BeliImporter.normalize(row.restaurantName) &&
                citiesMatch($0.city ?? "", row.city)
            }
            if existing.count == 1, duplicateGroups[identity(name: row.restaurantName, city: row.city)]?.count == 1 {
                resolutions[row.id] = .existing(existing[0].id)
                continue
            }
            let results = await locationService.search("\(row.restaurantName), \(row.city)")
            candidates[row.id] = results
            let exact = results.filter {
                BeliImporter.normalize($0.name) == BeliImporter.normalize(row.restaurantName) && citiesMatch($0.city ?? "", row.city)
            }
            if exact.count == 1, duplicateGroups[identity(name: row.restaurantName, city: row.city)]?.count == 1 {
                resolutions[row.id] = .map(exact[0])
            } else {
                resolutions[row.id] = .unresolved(markClosed: false)
            }
        }
        for photo in archive.photos {
            if let first = matchingRankings(in: archive, name: photo.restaurantName, city: photo.city).first {
                photoAssignments[photo.id] = first.id
            }
        }
        for dish in archive.dishNotes {
            if let first = matchingRankings(in: archive, name: dish.restaurantName, city: dish.city).first {
                dishAssignments[dish.id] = first.id
            }
        }
    }

    private func importArchive(_ archive: BeliParsedArchive) async {
        status = .importing(archive.photos.isEmpty ? "Importing dining history…" : "Downloading and preparing Beli photos…")
        let downloads = await BeliPhotoDownloader.download(archive.photos)
        if Task.isCancelled { return }
        status = .importing("Saving dining history…")
        let request = BeliImportRequest(
            archive: archive, resolutions: resolutions,
            photoRankingAssignments: photoAssignments, dishRankingAssignments: dishAssignments,
            downloadedPhotos: downloads.photos
        )
        var summary = store.importBeli(request)
        summary.failedPhotos = downloads.failures.count
        onComplete?(summary)
        Haptics.success()
        status = .complete(summary)
    }

    private func options(for row: BeliRankingRow) -> [ResolutionOption] {
        var values: [ResolutionOption] = []
        values.append(contentsOf: store.locations
            .filter { BeliImporter.normalize($0.name).contains(BeliImporter.normalize(row.restaurantName)) || BeliImporter.normalize(row.restaurantName).contains(BeliImporter.normalize($0.name)) }
            .prefix(8)
            .map { .init(title: "Existing · \($0.name) · \($0.address ?? $0.city ?? "No address")", resolution: .existing($0.id)) })
        values.append(contentsOf: (candidates[row.id] ?? []).prefix(8).map {
            .init(title: "Apple Maps · \($0.name) · \($0.address ?? $0.city ?? "No address")", resolution: .map($0))
        })
        values.append(.init(title: "Keep as separate, unverified restaurant", resolution: .unresolved(markClosed: false)))
        values.append(.init(title: "Keep separately and mark closed", resolution: .unresolved(markClosed: true)))
        values.append(.init(title: "Skip this Beli row", resolution: .skip))
        return values.uniqued(by: \.resolution)
    }

    private func resolutionBinding(for row: BeliRankingRow) -> Binding<BeliLocationResolution> {
        Binding(get: { resolutions[row.id] ?? .unresolved(markClosed: false) }, set: { resolutions[row.id] = $0 })
    }

    private var ambiguousPhotos: [BeliPhotoRow] {
        guard let archive else { return [] }
        return archive.photos.filter { matchingRankings(name: $0.restaurantName, city: $0.city).count > 1 }
    }

    private func photoAssignmentBinding(_ photo: BeliPhotoRow) -> Binding<String> {
        let fallback = matchingRankings(name: photo.restaurantName, city: photo.city).first?.id ?? ""
        return Binding(get: { photoAssignments[photo.id] ?? fallback }, set: { photoAssignments[photo.id] = $0 })
    }

    private func matchingRankings(name: String, city: String) -> [BeliRankingRow] {
        guard let archive else { return [] }
        return matchingRankings(in: archive, name: name, city: city)
    }

    private func matchingRankings(in archive: BeliParsedArchive, name: String, city: String) -> [BeliRankingRow] {
        archive.rankings.filter { identity(name: $0.restaurantName, city: $0.city) == identity(name: name, city: city) }
    }

    private func identity(name: String, city: String) -> String {
        "\(BeliImporter.normalize(name))|\(BeliImporter.normalize(city))"
    }

    private func citiesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ",").first.map(String.init) ?? lhs
        let right = rhs.split(separator: ",").first.map(String.init) ?? rhs
        return BeliImporter.normalize(left) == BeliImporter.normalize(right)
    }

    private struct ResolutionOption: Identifiable {
        let title: String
        let resolution: BeliLocationResolution
        var id: BeliLocationResolution { resolution }
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
