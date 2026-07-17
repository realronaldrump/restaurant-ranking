import CoreLocation
import PhotosUI
import SwiftUI

@MainActor
struct BackfillView: View {
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var clusters: [BackfillCluster] = []
    @State private var index = 0
    @State private var candidates: [PlaceCandidate] = []
    @State private var query = ""
    @State private var isProcessing = false
    @State private var importedVisits = 0
    @State private var rejected = 0
    @State private var startDate = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    @State private var endDate = Date.now
    @State private var errorMessage: String?
    @State private var pendingRatingVisit: VisitEntity?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if clusters.isEmpty { introduction } else if index < clusters.count { confirmationCard(clusters[index]) } else { completion }
            }.padding(18).padding(.bottom, 28).readablePageWidth()
        }
        .editorialPage().navigationTitle("Backfill").navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedItems) { _, items in if !items.isEmpty { Task { await loadSelected(items) } } }
        .sheet(item: $pendingRatingVisit, onDismiss: { advance() }) { visit in
            BackfillRatingView(visit: visit)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) { Eyebrow("Add past visits"); Text("Find meals in your photos").font(BBTheme.display(38)); Text("Choose photos, then confirm the restaurant. Nothing is added until you approve it.").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 15) {
                Eyebrow("Recommended")
                Text("Choose specific photos").font(BBTheme.display(25))
                Text("The standard picker grants access only to what you select. No library permission is needed.").font(.callout).foregroundStyle(.secondary)
                PhotosPicker(selection: $selectedItems, maxSelectionCount: 100, matching: .images) { Label("Choose Meal Photos", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle())
            }.ledgerCard()
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("Optional full-library search")
                Text("Scan a date range").font(BBTheme.display(25))
                Text("This scans photos on your device and requires Photo Library access.").font(.callout).foregroundStyle(.secondary)
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                DatePicker("Through", selection: $endDate, in: startDate..., displayedComponents: .date)
                Button { Task { await scanLibrary() } } label: { Label("Scan This Range", systemImage: "calendar.badge.magnifyingglass").frame(maxWidth: .infinity) }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 2)).frame(minHeight: 48)
            }.ledgerCard()
            if isProcessing { HStack { ProgressView(); Text("Reading photo dates and locations…") }.font(.callout) }
            if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(BBTheme.oxblood) }
            privacyNote
        }
    }

    private func confirmationCard(_ cluster: BackfillCluster) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Eyebrow("Candidate \(index + 1) of \(clusters.count)"); Spacer(); Text("\(Int(Double(index) / Double(max(1, clusters.count)) * 100))%").font(.caption.monospacedDigit()) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 5) {
                    ForEach(cluster.photos) { photo in
                        if let image = PhotoImageCache.thumbnail(key: "backfill-\(photo.id.uuidString)", data: photo.thumbnailData ?? photo.fullData) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 145, height: 145).clipped()
                        }
                    }
                }
            }
            Text("\(cluster.photos.count) \(cluster.photos.count == 1 ? "photo" : "photos") from \(cluster.date.formatted(date: .long, time: .shortened))").font(BBTheme.display(24))
            if cluster.coordinate == nil { Text("These selected copies did not include coordinates. Search for the place below.").font(.callout).foregroundStyle(.secondary) }
            HStack { Image(systemName: "magnifyingglass"); TextField("Search nearby establishments", text: $query); if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") } } }.padding(.horizontal, 13).frame(minHeight: 48).background(BBTheme.ink.opacity(0.055)).overlay(Rectangle().stroke(BBTheme.hairline))
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow("Which was it?")
                if candidates.isEmpty { Text(locationService.isSearching ? "Looking for nearby food establishments…" : "Search above to find the place.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12) }
                ForEach(candidates.prefix(8)) { candidate in
                    Button { confirm(cluster, candidate: candidate) } label: { HStack { Image(systemName: candidate.suggestedCategory.symbol).foregroundStyle(BBTheme.oxblood).frame(width: 28); VStack(alignment: .leading) { Text(candidate.name).font(.headline); Text(candidate.address ?? candidate.suggestedCategory.shortTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Image(systemName: "chevron.right").font(.caption) }.padding(.vertical, 8) }.buttonStyle(.plain)
                }
            }
            HStack { Button("Not a Meal", role: .destructive) { rejected += 1; advance() }.frame(minHeight: 44); Spacer(); Button("Skip") { advance() }.frame(minHeight: 44) }
            Text("Confirming adds an unrated visit at the photo’s date and time. You can rate it now or later.").font(.footnote).foregroundStyle(.secondary)
        }
        .task(id: "\(index)-\(query)") {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 10 : 260))
            guard !Task.isCancelled else { return }
            let radius: CLLocationDistance = cluster.coordinate != nil && query.isEmpty ? 150 : 9_000
            candidates = await locationService.search(query.isEmpty ? "restaurant cafe bakery bar" : query, around: cluster.coordinate, radius: radius)
        }
    }

    private var completion: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 60); Image(systemName: "photo.stack.fill").font(.system(size: 55, weight: .light)).foregroundStyle(BBTheme.oxblood)
            Eyebrow("Finished")
            Text("Backfill complete").font(BBTheme.display(36)).multilineTextAlignment(.center)
            Text("\(importedVisits) visits added · \(rejected) skipped").foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Scan More Photos") { clusters = []; index = 0; selectedItems = []; candidates = []; importedVisits = 0; rejected = 0 }.buttonStyle(PrimaryButtonStyle())
            Spacer(minLength: 40)
        }.frame(maxWidth: .infinity)
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 7) { Label("Photo privacy", systemImage: "lock.shield.fill").font(.headline); Text("Originals are unchanged. Saved copies have GPS metadata removed. Apple Maps receives coordinates only when you search for a place.").font(.callout).foregroundStyle(.secondary) }.padding(.vertical, 8)
    }

    private func loadSelected(_ items: [PhotosPickerItem]) async {
        isProcessing = true; errorMessage = nil
        var photos: [BackfillPhoto] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let photo = ImageSanitizer.process(data) { photos.append(photo) }
        }
        clusters = ImageSanitizer.clusters(photos); index = 0; isProcessing = false
        if clusters.isEmpty { errorMessage = "No readable image data was returned by the picker." }
    }

    private func scanLibrary() async {
        isProcessing = true; errorMessage = nil
        do { clusters = ImageSanitizer.clusters(try await PhotoLibraryScanner.scan(from: startDate, through: endDate)); index = 0 }
        catch { errorMessage = error.localizedDescription }
        isProcessing = false
    }

    private func confirm(_ cluster: BackfillCluster, candidate: PlaceCandidate) {
        let location = store.createLocation(name: candidate.name, category: candidate.suggestedCategory, address: candidate.address, city: candidate.city, coordinate: (candidate.latitude, candidate.longitude), phone: candidate.phone, url: candidate.url, sourceIdentifier: candidate.id, cuisines: candidate.cuisines)
        let visitCoordinate = cluster.coordinate.map { ($0.latitude, $0.longitude) }
        let visit = store.logVisit(at: location, reaction: nil, date: cluster.date, coordinate: visitCoordinate)
        for photo in cluster.photos { store.addPhoto(fullData: photo.fullData, thumbnailData: photo.thumbnailData, to: visit, createdAt: photo.date) }
        importedVisits += 1; Haptics.success(); pendingRatingVisit = visit
    }
    private func advance() { query = ""; candidates = []; withAnimation { index += 1 } }
}

@MainActor
private struct BackfillRatingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    @State private var reaction: Reaction?
    @State private var hazy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Eyebrow("Past visit")
                    Text(visit.location?.name ?? "Meal").font(BBTheme.display(35))
                    Text(visit.date.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                    Text("How clearly do you remember it?").font(BBTheme.display(24))
                    ReactionPicker(selected: reaction) { reaction = $0 }
                    Toggle("Hazy memory · weight this lightly", isOn: $hazy)
                    Button("Save Rating") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(reaction == nil)
                    Button("Leave This Visit Unrated") { dismiss() }.frame(maxWidth: .infinity).frame(minHeight: 48)
                    Text("An unrated visit still counts fully in history and not at all in rankings.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }.padding(20).readablePageWidth()
            }.editorialPage().navigationTitle("Backfill Rating").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Unrated") { dismiss() } } }
        }
    }
    private func save() {
        guard let reaction, let personID = store.currentPerson?.id else { return }
        _ = store.addRating(to: visit, personID: personID, reaction: reaction, hazy: hazy)
        Haptics.success(); dismiss()
    }
}
