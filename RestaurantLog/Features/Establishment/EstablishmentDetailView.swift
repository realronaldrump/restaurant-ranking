import MapKit
import SwiftUI

private struct EstablishmentMemberScore: Identifiable {
    let person: PersonEntity
    let value: Double
    var id: UUID { person.id }
}

@MainActor
struct EstablishmentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    let location: RestaurantLocation
    var rankingScope: RankingScope? = nil
    @State private var editingLocation: RestaurantLocation?
    @State private var selectedPhoto: PhotoEntity?
    @State private var showsSplitDecisionExplanation = false
    @State private var confirmsRestaurantRemoval = false
    @State private var pendingRestaurantDeletionID: UUID?

    @ViewBuilder var body: some View {
        Group {
            if location.managedObjectContext == nil || location.isDeleted {
                EmptyView()
            } else {
                establishmentContent
            }
        }
        .onDisappear { finishPendingRestaurantDeletion() }
    }

    private var establishmentContent: some View {
        let visits = location.visitArray
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                hero(visits: visits)
                dishHonors
                visitTimeline(visits)
                photoGrid(visits)
                scoreBreakdown(visits)
                scoreHistory(visits)
                practicalInformation
            }
            .padding(.bottom, 112).readablePageWidth()
        }
        .editorialPage()
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { router.sheet = .logMealAt(location.id) } label: {
                Label("Log an outing here", systemImage: "plus.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, BBTheme.Spacing.page)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { store.toggleWant(location) } label: { Image(systemName: store.isWanted(location) ? "bookmark.fill" : "bookmark") }.accessibilityLabel(store.isWanted(location) ? "Remove from Want to Try" : "Add to Want to Try")
                Menu {
                    Button("Compare directly", systemImage: "arrow.left.arrow.right") { router.sheet = .compare(location.id) }
                    Button("Edit details", systemImage: "pencil") { editingLocation = location }
                    Button(location.isClosed ? "Mark open" : "Mark closed", systemImage: "door.left.hand.closed") {
                        store.updateLocation(location, name: location.name, category: location.category, cuisines: location.cuisines, tags: location.tags, isClosed: !location.isClosed)
                    }
                    if store.canDeleteRestaurant(location) {
                        Divider()
                        Button("Remove restaurant", systemImage: "trash", role: .destructive) {
                            confirmsRestaurantRemoval = true
                        }
                        .accessibilityIdentifier("remove-empty-restaurant")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Restaurant actions")
            }
        }
        .sheet(item: $editingLocation) { EditLocationView(location: $0) }
        .fullScreenCover(item: $selectedPhoto) { PhotoViewer(photo: $0) }
        .editorialPrompt(isPresented: $confirmsRestaurantRemoval) {
            EditorialPrompt.destructive(
                "Remove \(location.name) from the log?",
                message: "This restaurant has no outings. Removing it also deletes any Want to Try entry and every comparison involving it for everyone in your circle.",
                actionTitle: "Remove restaurant",
                actionSymbol: "trash",
                cancelTitle: "Cancel"
            ) {
                removeRestaurant()
            }
        }
        .editorialPrompt(isPresented: $showsSplitDecisionExplanation) {
            EditorialPrompt(
                "Opinions vary",
                message: "People in your circle scored this restaurant at least 15 points apart. Everyone keeps their own ranking.",
                tone: .information,
                actions: [.cancel("Got It")]
            )
        }
    }

    private func removeRestaurant() {
        guard store.canDeleteRestaurant(location) else {
            confirmsRestaurantRemoval = false
            return
        }
        pendingRestaurantDeletionID = location.id
        confirmsRestaurantRemoval = false
        Task { @MainActor in
            await Task.yield()
            dismiss()
        }
    }

    private func finishPendingRestaurantDeletion() {
        guard let restaurantID = pendingRestaurantDeletionID else { return }
        pendingRestaurantDeletionID = nil
        Task { @MainActor in
            await Task.yield()
            guard store.deleteRestaurant(id: restaurantID) else { return }
            router.removeRoutes(toDeletedRestaurant: restaurantID)
        }
    }

    private func hero(visits: [VisitEntity]) -> some View {
        let cuisines = location.cuisines
        let tags = location.tags
        let myScore = store.score(for: location)
        let memberScores: [EstablishmentMemberScore] = store.circleMembers.compactMap { person in
            store.score(for: location, personID: person.id).map { .init(person: person, value: $0.score) }
        }
        let circleScore = store.circleRanked().first { $0.id == location.id }
        let displayedScore = displayedScore(myScore: myScore, circleScore: circleScore)
        let heroPhoto = visits.lazy.flatMap(\.photoArray).first

        return VStack(alignment: .leading, spacing: 0) {
            if let heroPhoto {
                PhotoImage(photo: heroPhoto, displayPixels: 1_400)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .clipped()
            } else {
                CategoryArtwork(category: location.category, height: 190)
            }

            VStack(alignment: .leading, spacing: 22) {
                heroIdentity(cuisines: cuisines, tags: tags)

                if let displayedScore {
                    scoreAndRankings(
                        displayedScore,
                        myScore: myScore,
                        circleScore: circleScore
                    )
                }

                if circleScore?.isSplitDecision == true {
                    splitDecisionCallout
                }

                if memberScores.contains(where: { $0.person.id != store.currentPerson?.id }) {
                    circleScoreBreakdown(memberScores: memberScores, circleScore: circleScore)
                }
            }
            .padding(20)
        }
        .background(BBTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous)
                .stroke(BBTheme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
        .padding(.horizontal, BBTheme.Spacing.page)
    }

    private func heroIdentity(cuisines: [String], tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Eyebrow("Restaurant")
                if location.isClosed {
                    Text("Closed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BBTheme.oxblood)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(BBTheme.oxblood.opacity(0.09), in: Capsule())
                }
            }
            Text(location.name)
                .font(BBTheme.display(36))
                .fixedSize(horizontal: false, vertical: true)
            Text(location.category.rawValue)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !cuisines.isEmpty || !tags.isEmpty {
                FlowLayout(items: cuisines + tags) { tag in
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(BBTheme.ink.opacity(0.06), in: Capsule())
                }
            }
        }
    }

    private func scoreAndRankings(
        _ displayedScore: DisplayedScore,
        myScore: LocationScore?,
        circleScore: CircleLocationScore?
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow("Return score")
                scoreMark(displayedScore, size: 52)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let ranks = rankingData(myScore: myScore, circleScore: circleScore) {
                Rectangle()
                    .fill(BBTheme.hairline)
                    .frame(width: 1, height: 62)

                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow("Rankings")
                    rankLine(label: location.category.shortTitle, value: "#\(ranks.categoryRank)")
                    rankLine(label: "Overall", value: "#\(ranks.overallRank)")
                }
                .frame(width: 118, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    private func rankingData(
        myScore: LocationScore?,
        circleScore: CircleLocationScore?
    ) -> (categoryRank: Int, overallRank: Int)? {
        switch rankingScope {
        case .circle:
            return circleScore.map { ($0.categoryRank, $0.overallRank) }
        case .person(let personID):
            return store.score(for: location, personID: personID).map { ($0.categoryRank, $0.overallRank) }
        case nil:
            return myScore.map { ($0.categoryRank, $0.overallRank) }
        }
    }

    private func rankLine(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(value)
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(BBTheme.oxblood)
        }
    }

    private var splitDecisionCallout: some View {
        Button { showsSplitDecisionExplanation = true } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(BBTheme.oxblood)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Opinions vary")
                        .font(.subheadline.weight(.semibold))
                    Text("Circle scores differ by 15+ points")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BBTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Explains why people in the circle scored this differently")
    }

    private func circleScoreBreakdown(
        memberScores: [EstablishmentMemberScore],
        circleScore: CircleLocationScore?
    ) -> some View {
        let columnCount = memberScores.count + (circleScore == nil ? 0 : 1)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)

        return VStack(alignment: .leading, spacing: 12) {
            Divider()
            Eyebrow("Circle scores")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(memberScores) { member in
                    compactScore(name: member.person.name, value: member.value)
                }
                if let circleScore {
                    compactScore(name: "Circle", value: circleScore.score)
                }
            }
        }
    }

    private struct DisplayedScore {
        let score: Double
        let caption: String
        let provisional: Bool
    }

    private func displayedScore(myScore: LocationScore?, circleScore: CircleLocationScore?) -> DisplayedScore? {
        switch rankingScope {
        case .circle:
            return circleScore.map { .init(score: $0.score, caption: "Circle · out of 100", provisional: $0.isProvisional) }
        case .person(let personID):
            return store.score(for: location, personID: personID).map {
                .init(score: $0.score, caption: "\(store.person(id: personID)?.name ?? "Personal") · out of 100", provisional: $0.isProvisional)
            }
        case nil:
            return myScore.map { .init(score: $0.score, caption: "\(store.currentPerson?.name ?? "You") · out of 100", provisional: $0.isProvisional) }
        }
    }

    @ViewBuilder
    private func scoreMark(_ displayedScore: DisplayedScore, size: CGFloat) -> some View {
        if displayedScore.provisional {
            Button { router.sheet = .compare(location.id) } label: {
                ScoreMark(
                    score: displayedScore.score,
                    caption: displayedScore.caption,
                    size: size,
                    provisional: true,
                    showsDecimal: true,
                    alignment: .leading
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens a comparison to sharpen this score")
        } else {
            ScoreMark(
                score: displayedScore.score,
                caption: displayedScore.caption,
                size: size,
                showsDecimal: true,
                alignment: .leading
            )
        }
    }

    @ViewBuilder private var dishHonors: some View {
        let scores = dishScores
        if !scores.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Best and worst dishes")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    dishHonor("HIGHEST RATED", item: scores.first, positive: true)
                    dishHonor("LOWEST RATED", item: scores.count > 1 ? scores.last : nil, positive: false)
                }
            }.padding(.horizontal, 16)
        }
    }

    private func visitTimeline(_ visits: [VisitEntity]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            EditorialSectionHeader("Outings", eyebrow: "\(visits.count) \(visits.count == 1 ? "outing" : "outings")")
            if visits.isEmpty { EmptyLogView(title: "No outings yet", message: "Nothing logged here so far.", symbol: "calendar") }
            ForEach(visits, id: \.objectID) { visit in
                NavigationLink(value: AppRoute.visit(visit.id)) { VisitRow(visit: visit) }.buttonStyle(.plain)
                if visit.id != visits.last?.id { Divider() }
            }
        }.padding(.horizontal, 16)
    }

    @ViewBuilder private func photoGrid(_ visits: [VisitEntity]) -> some View {
        let photos = visits.flatMap(\.photoArray)
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Photos", eyebrow: "\(photos.count) \(photos.count == 1 ? "photo" : "photos")")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 4)], spacing: 4) {
                    ForEach(photos, id: \.objectID) { photo in
                        Button { selectedPhoto = photo } label: {
                            PhotoImage(photo: photo).frame(minHeight: 108).aspectRatio(1, contentMode: .fill).clipped()
                        }.buttonStyle(.plain).accessibilityLabel("Open outing photo")
                    }
                }
            }.padding(.horizontal, 16)
        }
    }

    private func scoreBreakdown(_ visits: [VisitEntity]) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            EditorialSectionHeader("Your reactions")
            if let summary = breakdown(for: visits) {
                Text(summary.explanation).font(BBTheme.display(20, weight: .regular))
                metricBar("Overall reaction", value: summary.food)
                metricBar("Value", value: summary.value)
                metricBar("Service", value: summary.service)
                metricBar("Atmosphere", value: summary.atmosphere)
                Text("These bars show your average reactions. The return score above also weighs how recent an outing was and any comparisons you have made, so the numbers can differ.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else { Text("This fills in once you add a reaction to an outing here.").foregroundStyle(.secondary) }
        }.padding(.horizontal, 16).padding(.vertical, 4)
    }

    @ViewBuilder private func scoreHistory(_ visits: [VisitEntity]) -> some View {
        let points = scorePoints(for: visits)
        if points.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Score over time")
                ScoreSparkline(points: points).frame(height: 110).accessibilityLabel("Return score history from \(points.first?.formatted(.number.precision(.fractionLength(1))) ?? "") to \(points.last?.formatted(.number.precision(.fractionLength(1))) ?? "")")
            }.padding(.horizontal, 16)
        }
    }

    private var practicalInformation: some View {
        let coordinate = location.coordinate
        return VStack(alignment: .leading, spacing: 14) {
            EditorialSectionHeader("Practical information")
            if let coordinate {
                Map(initialPosition: .region(.init(center: .init(latitude: coordinate.latitude, longitude: coordinate.longitude), latitudinalMeters: 1_400, longitudinalMeters: 1_400))) {
                    Marker(location.name, coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude)).tint(BBTheme.oxblood)
                }
                .frame(height: 180)
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
                .accessibilityHidden(true)
            }
            if let address = location.address { Label(address, systemImage: "mappin.and.ellipse") }
            if let hours = location.hoursText { Label(hours, systemImage: "clock") }
            if let phone = location.phone, let url = URL(string: "tel:\(phone.filter { $0.isNumber })") { Link(destination: url) { Label(phone, systemImage: "phone") } }
            if let urlString = location.urlString, let url = URL(string: urlString) { Link(destination: url) { Label("Website or menu", systemImage: "safari") } }
            if coordinate != nil {
                Button { openDirections() } label: { Label("Open in Maps", systemImage: "arrow.triangle.turn.up.right.diamond") }.buttonStyle(SecondaryButtonStyle())
            }
        }.padding(.horizontal, 16)
    }

    private func compactScore(name: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(name.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(value?.formatted(.number.precision(.fractionLength(1))) ?? "—").font(BBTheme.score(25)) }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dishScores: [(name: String, score: Double)] {
        guard let personID = store.currentPerson?.id else { return [] }
        return location.dishArray.compactMap { dish in
            let entries = dish.entryArray.filter { $0.personID == personID }
            guard !entries.isEmpty else { return nil }
            return (dish.name, entries.map { $0.reaction.anchor }.reduce(0, +) / Double(entries.count))
        }.sorted { $0.score > $1.score }
    }

    private func dishHonor(_ eyebrow: String, item: (name: String, score: Double)?, positive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(positive ? BBTheme.sage : BBTheme.oxblood)
            Text(item?.name ?? "Not enough dish entries yet").font(BBTheme.display(19)).lineLimit(2)
            if let item { Text(item.score.formatted(.number.precision(.fractionLength(0)))).font(BBTheme.score(25)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading).editorialCard()
    }

    private struct Breakdown { let food: Double; let value: Double?; let service: Double?; let atmosphere: Double?; let explanation: String }
    private func breakdown(for visits: [VisitEntity]) -> Breakdown? {
        guard let personID = store.currentPerson?.id else { return nil }
        let ratings = visits.compactMap { $0.rating(for: personID) }
        guard !ratings.isEmpty else { return nil }
        func avg(_ values: [Reaction]) -> Double? { values.isEmpty ? nil : values.map(\.anchor).reduce(0, +) / Double(values.count) }
        let food = avg(ratings.map(\.reaction)) ?? 55
        let value = avg(ratings.compactMap(\.value))
        let service = avg(ratings.compactMap(\.service))
        let atmosphere = avg(ratings.compactMap(\.atmosphere))
        let rated: [(String, Double)] = [("overall reaction", food)] + [("value", value), ("service", service), ("atmosphere", atmosphere)].compactMap { name, score in score.map { (name, $0) } }
        let explanation: String
        if rated.count <= 1 {
            explanation = "Based on your overall reactions."
        } else if let strongest = rated.max(by: { $0.1 < $1.1 }), let weakest = rated.min(by: { $0.1 < $1.1 }), strongest.0 != weakest.0, strongest.1 - weakest.1 > 2 {
            explanation = "Highest for \(strongest.0) and lowest for \(weakest.0)."
        } else {
            explanation = "Your reactions are consistent across categories."
        }
        return .init(food: food, value: value, service: service, atmosphere: atmosphere, explanation: explanation)
    }

    private func metricBar(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Text(value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "Not rated").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let value {
                ProgressView(value: value, total: 100)
                    .tint(BBTheme.oxblood)
            } else {
                Label("Not rated", systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "not yet rated")")
    }

    private func scorePoints(for visits: [VisitEntity]) -> [Double] {
        guard let personID = store.currentPerson?.id else { return [] }
        var total = 0.0, weight = 0.0
        return visits.reversed().compactMap { visit in
            guard let rating = visit.rating(for: personID) else { return nil }
            total += store.rankingEngine.visitValue(visit: visit, rating: rating); weight += 1
            return total / weight
        }
    }

    private func openDirections() {
        guard let coordinate = location.coordinate else { return }
        let placemark = MKPlacemark(coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude))
        let item = MKMapItem(placemark: placemark); item.name = location.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

struct ScoreSparkline: View {
    let points: [Double]
    var body: some View {
        Canvas { context, size in
            guard points.count > 1, let minValue = points.min(), let maxValue = points.max() else { return }
            let range = max(8, maxValue - minValue)
            var path = Path()
            for index in points.indices {
                let x = size.width * CGFloat(index) / CGFloat(points.count - 1)
                let y = size.height - (CGFloat((points[index] - minValue) / range) * (size.height - 16) + 8)
                if index == 0 { path.move(to: .init(x: x, y: y)) } else { path.addLine(to: .init(x: x, y: y)) }
            }
            context.stroke(path, with: .color(BBTheme.oxblood), style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
            for index in points.indices {
                let x = size.width * CGFloat(index) / CGFloat(points.count - 1)
                let y = size.height - (CGFloat((points[index] - minValue) / range) * (size.height - 16) + 8)
                context.fill(Path(ellipseIn: .init(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(BBTheme.oxblood))
            }
        }
        .padding(.vertical, 4)
    }
}

struct FlowLayout<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        WrappingRowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

private struct WrappingRowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var usedHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = rowWidth == 0 ? size.width : rowWidth + horizontalSpacing + size.width
            if proposedWidth > maxWidth, rowWidth > 0 {
                usedWidth = max(usedWidth, rowWidth)
                usedHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = proposedWidth
                rowHeight = max(rowHeight, size.height)
            }
        }
        usedWidth = max(usedWidth, rowWidth)
        usedHeight += rowHeight
        return CGSize(width: proposal.width ?? usedWidth, height: usedHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

@MainActor
struct EditLocationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let location: RestaurantLocation
    @State private var name: String
    @State private var category: DiningCategory
    @State private var cuisines: String
    @State private var tags: String
    @State private var address: String
    @State private var city: String
    @State private var phone: String
    @State private var urlString: String
    @State private var hoursText: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var isClosed: Bool

    init(location: RestaurantLocation) {
        self.location = location
        _name = State(initialValue: location.name); _category = State(initialValue: location.category)
        _cuisines = State(initialValue: location.cuisines.joined(separator: ", ")); _tags = State(initialValue: location.tags.joined(separator: ", "))
        _address = State(initialValue: location.address ?? ""); _city = State(initialValue: location.city ?? "")
        _phone = State(initialValue: location.phone ?? ""); _urlString = State(initialValue: location.urlString ?? "")
        _hoursText = State(initialValue: location.hoursText ?? "")
        _latitude = State(initialValue: location.hasCoordinates ? String(location.latitude) : "")
        _longitude = State(initialValue: location.hasCoordinates ? String(location.longitude) : "")
        _isClosed = State(initialValue: location.isClosed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Primary category", selection: $category) {
                        ForEach(DiningCategory.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: { Eyebrow("Name") }
                .listRowBackground(BBTheme.surface)

                Section {
                    TextField("Cuisines, separated by commas", text: $cuisines)
                    TextField("Tags, separated by commas", text: $tags)
                } header: { Eyebrow("Cuisines and tags") }
                .listRowBackground(BBTheme.surface)

                Section {
                    TextField("Street address", text: $address)
                    TextField("City", text: $city)
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                    TextField("Website or menu URL", text: $urlString).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Hours", text: $hoursText)
                } header: { Eyebrow("Practical information") }
                .listRowBackground(BBTheme.surface)

                Section {
                    TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                } header: { Eyebrow("Map coordinates") } footer: { Text("Optional. Clearing either field removes the map pin.") }
                .listRowBackground(BBTheme.surface)

                Section {
                    Toggle("Closed", isOn: $isClosed)
                } header: { Eyebrow("Availability") } footer: {
                    Text("A closed restaurant keeps its full history but drops out of rankings and suggestions.")
                }
                .listRowBackground(BBTheme.surface)
            }.editorialForm()
            .navigationTitle("Edit Restaurant").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    private func save() {
        let parse: (String) -> [String] = { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        var normalizedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedURL.isEmpty, URL(string: normalizedURL)?.scheme == nil { normalizedURL = "https://\(normalizedURL)" }
        store.updateLocationDetails(
            location, name: name, category: category, cuisines: parse(cuisines), tags: parse(tags),
            address: address, city: city, phone: phone, urlString: normalizedURL, hoursText: hoursText,
            latitude: Double(latitude), longitude: Double(longitude), isClosed: isClosed
        )
        dismiss()
    }
}
