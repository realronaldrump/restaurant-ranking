import SwiftUI
import UIKit

struct RankingShareItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let city: String?
    let category: DiningCategory
    let score: Int
}

enum RankingCardStyle: String, CaseIterable, Identifiable {
    case supperClub = "Supper Club"
    case afterHours = "After Hours"
    case cherryPop = "Cherry Pop"
    var id: Self { self }
    var paper: Color {
        switch self {
        case .supperClub: Color(hex: "F5EBDC")
        case .afterHours: Color(hex: "201E22")
        case .cherryPop: Color(hex: "F6BAC8")
        }
    }
    var ink: Color {
        switch self {
        case .supperClub: Color(hex: "692737")
        case .afterHours: Color(hex: "F7E9CE")
        case .cherryPop: Color(hex: "931C34")
        }
    }
    var accent: Color {
        switch self {
        case .supperClub: Color(hex: "B74C53")
        case .afterHours: Color(hex: "EBB96C")
        case .cherryPop: Color(hex: "AB233D")
        }
    }
}

struct RankingCardOptions {
    var title = "My rankings"
    var caption = ""
    var style: RankingCardStyle = .supperClub
    var showsScores = true
    var showsCities = true
}

/// Plain values make the preview and exported image an identical snapshot.
struct RankingShareCard: View {
    let items: [RankingShareItem]
    let attribution: String
    let options: RankingCardOptions
    static let width: CGFloat = 540

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "fork.knife").font(.system(size: 18, weight: .semibold))
                Text("RESTAURANT RANKINGS")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(3)
                Spacer()
                Text(String(format: "%02d PICKS", items.count))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1)
            }
            .padding(.bottom, 22)
            Rectangle().fill(options.style.ink).frame(height: 2)
            HStack(alignment: .top, spacing: 16) {
                Text(options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My rankings" : options.title)
                    .font(.system(size: 49, weight: .bold, design: .serif))
                    .tracking(-2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle().stroke(options.style.ink.opacity(0.6), lineWidth: 1)
                    Circle().stroke(options.style.ink.opacity(0.6), lineWidth: 1).padding(6)
                    Image(systemName: "fork.knife")
                        .font(.system(size: 30, weight: .light))
                }
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(12))
                .padding(.top, 7)
            }
            .padding(.top, 26)
            Text(attribution.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .padding(.top, 20)
            if !options.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(options.caption)
                    .font(.system(size: 15, design: .serif).italic())
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.8)
                    .padding(.top, 8)
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    cardRow(item, rank: Self.rank(at: index, in: items))
                    if index < items.count - 1 {
                        Rectangle().fill(options.style.ink.opacity(0.22)).frame(height: 0.75)
                    }
                }
            }
            .padding(.top, 26)
            Spacer(minLength: 28)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("BIG BEAUTIFUL")
                        .font(.system(size: 11, weight: .black))
                        .tracking(2)
                    Text("RESTAURANT LOG")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(2.5)
                }
                Spacer()
                if options.showsScores {
                    Text("RETURN SCORES / 100")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                }
            }
            .padding(.top, 18)
            .overlay(alignment: .top) { Rectangle().fill(options.style.ink).frame(height: 2) }
        }
        .padding(36)
        .frame(width: Self.width, alignment: .leading)
        .frame(minHeight: 675)
        .foregroundStyle(options.style.ink)
        .background(options.style.paper)
        .overlay { Rectangle().strokeBorder(options.style.ink.opacity(0.25), lineWidth: 1).padding(12) }
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .medium)
    }

    private func cardRow(_ item: RankingShareItem, rank: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(String(format: "%02d", rank))
                .font(.system(size: 23, weight: .regular, design: .serif))
                .foregroundStyle(options.style.accent)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                if options.showsCities, let city = item.city, !city.isEmpty {
                    Text(city.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if options.showsScores {
                Text("\(item.score)")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(options.style.accent)
            }
        }
        .padding(.vertical, 16)
    }

    /// Ties use the same whole-number scores as the rankings screen.
    static func rank(at index: Int, in items: [RankingShareItem]) -> Int {
        guard items.indices.contains(index) else { return 0 }
        return (items.firstIndex { $0.score == items[index].score } ?? index) + 1
    }
}

@MainActor
struct RankingShareView: View {
    let items: [RankingShareItem]
    let attribution: String
    @Environment(\.dismiss) private var dismiss
    @State private var options = RankingCardOptions()
    @State private var category: DiningCategory?
    @State private var city: String?
    @State private var selectedIDs: Set<UUID> = []
    @State private var preview: UIImage?
    @State private var export: RankingPNGExport?
    @State private var error: String?
    @State private var rendering = false
    @State private var started = false

    private var candidates: [RankingShareItem] {
        items.filter { (category == nil || $0.category == category) && (city == nil || $0.city == city) }
    }
    private var selected: [RankingShareItem] { candidates.filter { selectedIDs.contains($0.id) } }
    private var cities: [String] { Array(Set(items.compactMap(\.city).filter { !$0.isEmpty })).sorted() }
    private var previewKey: String {
        [selected.map { $0.id.uuidString }.joined(), options.title, options.caption, options.style.rawValue,
         String(options.showsScores), String(options.showsCities)].joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 360)
                            .accessibilityLabel("Preview of your ranking card")
                            .accessibilityIdentifier("ranking-card-preview")
                    } else {
                        ContentUnavailableView("Pick your restaurants", systemImage: "list.number", description: Text("Choose up to 20 restaurants."))
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                .listRowBackground(BBTheme.surface)
                Section("Appearance") {
                    Picker("Style", selection: $options.style) {
                        ForEach(RankingCardStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Title", text: $options.title, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: options.title) { _, value in options.title = String(value.prefix(100)) }
                    TextField("Caption (optional)", text: $options.caption, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: options.caption) { _, value in options.caption = String(value.prefix(180)) }
                    Toggle("Show scores", isOn: $options.showsScores)
                    Toggle("Show cities", isOn: $options.showsCities)
                }
                Section {
                    Picker("Category", selection: $category) {
                        Text("All categories").tag(DiningCategory?.none)
                        ForEach(DiningCategory.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    Picker("City", selection: $city) {
                        Text("All cities").tag(String?.none)
                        ForEach(cities, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    HStack {
                        ForEach([5, 10, 20], id: \.self) { count in
                            Button("Top \(count)") { selectFirst(count) }
                                .buttonStyle(.bordered)
                        }
                    }
                    DisclosureGroup("Choose restaurants (\(selected.count) selected)") {
                        ForEach(candidates) { item in
                            Button { toggle(item.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).foregroundStyle(BBTheme.ink)
                                        if let city = item.city { Text(city).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                }
                                .frame(minHeight: 44)
                            }
                            .disabled(!selectedIDs.contains(item.id) && selected.count >= 20)
                            .accessibilityValue(selectedIDs.contains(item.id) ? "Selected" : "Not selected")
                        }
                    }
                } header: {
                    Text("What to include")
                } footer: {
                    Text("Uses your current ranking filters. Up to 20 restaurants per image.")
                }
            }
            .editorialForm()
            .navigationTitle("Share your rankings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        share()
                    } label: {
                        if rendering { ProgressView() } else { Label("Share PNG", systemImage: "square.and.arrow.up") }
                    }
                    .disabled(selected.isEmpty || rendering)
                    .accessibilityIdentifier("share-ranking-png")
                }
            }
            .onAppear {
                guard !started else { return }
                started = true
                selectFirst(10)
            }
            .onChange(of: category) { _, _ in selectFirst(10) }
            .onChange(of: city) { _, _ in selectFirst(10) }
            .task(id: previewKey) {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard !Task.isCancelled else { return }
                preview = selected.isEmpty ? nil : RankingPNGRenderer.image(items: selected, attribution: attribution, options: options, scale: 1)
            }
            .sheet(item: $export) { value in RankingPNGShareSheet(url: value.url) }
            .alert("Couldn’t create your image", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "Please try again.") }
        }
    }

    private func selectFirst(_ count: Int) { selectedIDs = Set(candidates.prefix(count).map(\.id)) }
    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else if selected.count < 20 { selectedIDs.insert(id) }
    }
    private func share() {
        rendering = true
        Task { @MainActor in
            await Task.yield()
            defer { rendering = false }
            do {
                export = try RankingPNGRenderer.export(items: selected, attribution: attribution, options: options)
                Haptics.success()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct RankingPNGExport: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
enum RankingPNGRenderer {
    static func image(items: [RankingShareItem], attribution: String, options: RankingCardOptions, scale: CGFloat = 2) -> UIImage? {
        let renderer = ImageRenderer(content: RankingShareCard(items: Array(items.prefix(20)), attribution: attribution, options: options))
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    static func export(items: [RankingShareItem], attribution: String, options: RankingCardOptions) throws -> RankingPNGExport {
        guard !items.isEmpty, let data = image(items: items, attribution: attribution, options: options)?.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RankingCards", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep this share's file stable while another app reads it. Expire old cards only.
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created < Date.now.addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: url) }
        }
        let url = directory.appendingPathComponent("My Rankings-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: url, options: .atomic)
        return RankingPNGExport(url: url)
    }
}

private struct RankingPNGShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
