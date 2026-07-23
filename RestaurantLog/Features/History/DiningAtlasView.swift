import MapKit
import SwiftUI

private struct DiningAtlasStop: Identifiable {
    let id: UUID
    let order: Int
    let locationID: UUID
    let name: String
    let city: String?
    let category: DiningCategory
    let coordinate: CLLocationCoordinate2D
    let firstVisitDate: Date
    let visitCount: Int
    let latestReaction: Reaction?
    let isClosed: Bool
}

private struct DiningAtlasSnapshot {
    let stops: [DiningAtlasStop]
    let loggedPlaceCount: Int

    var unmappedPlaceCount: Int { loggedPlaceCount - stops.count }
    var route: [CLLocationCoordinate2D] { stops.map(\.coordinate) }

    init(visits: [VisitEntity], personID: UUID?) {
        let orderedVisits = visits
            .filter { $0.managedObjectContext != nil && !$0.isDeleted && $0.location != nil }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.createdAt < $1.createdAt
            }

        var locationOrder: [UUID] = []
        var visitsByLocation: [UUID: [VisitEntity]] = [:]
        for visit in orderedVisits {
            guard let location = visit.location else { continue }
            if visitsByLocation[location.id] == nil { locationOrder.append(location.id) }
            visitsByLocation[location.id, default: []].append(visit)
        }

        loggedPlaceCount = locationOrder.count
        stops = locationOrder.enumerated().compactMap { offset, locationID in
            guard let locationVisits = visitsByLocation[locationID],
                  let firstVisit = locationVisits.first,
                  let location = firstVisit.location,
                  let coordinate = Self.coordinate(for: location, visits: locationVisits) else { return nil }

            let reaction = locationVisits.reversed().compactMap { visit -> Reaction? in
                guard let personID else { return visit.ratingArray.first?.reaction }
                return visit.rating(for: personID)?.reaction
            }.first

            return DiningAtlasStop(
                id: locationID,
                order: offset + 1,
                locationID: locationID,
                name: location.name,
                city: location.city,
                category: location.category,
                coordinate: coordinate,
                firstVisitDate: firstVisit.date,
                visitCount: locationVisits.count,
                latestReaction: reaction,
                isClosed: location.isClosed
            )
        }
    }

    private static func coordinate(
        for location: RestaurantLocation,
        visits: [VisitEntity]
    ) -> CLLocationCoordinate2D? {
        if location.hasCoordinates {
            let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
            if CLLocationCoordinate2DIsValid(coordinate) { return coordinate }
        }

        return visits.lazy.compactMap { visit in
            guard visit.hasCoordinates else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }.first
    }
}

@MainActor
struct DiningAtlasView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedStopID: UUID?
    @State private var snapshot = DiningAtlasSnapshot(visits: [], personID: nil)
    @State private var isPreparing = true

    var body: some View {
        Group {
            if isPreparing {
                ProgressView("Building your atlas…")
                    .tint(BBTheme.oxblood)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot.loggedPlaceCount == 0 {
                emptyAtlas(
                    title: "Your atlas is waiting",
                    message: "Log a meal and its place will become the first stop in your dining story.",
                    symbol: "map"
                )
            } else if snapshot.stops.isEmpty {
                emptyAtlas(
                    title: "No places to pin yet",
                    message: "Your logged places do not have map coordinates. Add a location from a place’s details to put it on the atlas.",
                    symbol: "mappin.slash"
                )
            } else {
                atlas(snapshot)
            }
        }
        .task(id: store.revision) {
            snapshot = DiningAtlasSnapshot(visits: store.visits, personID: store.currentPerson?.id)
            isPreparing = false
        }
        .navigationTitle("Dining Atlas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !snapshot.stops.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if reduceMotion { position = .automatic }
                        else { withAnimation(.easeInOut(duration: 0.45)) { position = .automatic } }
                        Haptics.selection()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Show every place")
                }
            }
        }
        .editorialPage()
    }

    private func atlas(_ snapshot: DiningAtlasSnapshot) -> some View {
        Map(position: $position) {
            if snapshot.route.count > 1 {
                MapPolyline(coordinates: snapshot.route)
                    .stroke(
                        BBTheme.oxblood.opacity(0.52),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [2, 7])
                    )
            }

            ForEach(snapshot.stops) { stop in
                Annotation("", coordinate: stop.coordinate, anchor: .bottom) {
                    Button {
                        if reduceMotion { selectedStopID = stop.id }
                        else { withAnimation(.spring(duration: 0.34, bounce: 0.18)) { selectedStopID = stop.id } }
                        Haptics.selection()
                    } label: {
                        DiningAtlasPin(number: stop.order, isSelected: selectedStopID == stop.id)
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop \(stop.order), \(stop.name)")
                    .accessibilityHint("Shows details for this place")
                }
            }
        }
        .mapStyle(
            .standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            )
        )
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .top) { atlasHeader(snapshot) }
        .safeAreaInset(edge: .bottom, spacing: 0) { stopCard(snapshot) }
        .onAppear { selectDefaultStop(from: snapshot) }
        .onChange(of: snapshot.stops.map(\.id)) { _, _ in selectDefaultStop(from: snapshot) }
    }

    private func atlasHeader(_ snapshot: DiningAtlasSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    atlasTitle(snapshot)
                    Spacer(minLength: 12)
                    routeKey
                }
                VStack(alignment: .leading, spacing: 8) {
                    atlasTitle(snapshot)
                    routeKey
                }
            }
            Text(headerDetail(snapshot))
                .font(.caption)
                .foregroundStyle(BBTheme.ink.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(BBTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous)
                .stroke(BBTheme.ink.opacity(0.14))
        }
        .shadow(color: BBTheme.ink.opacity(0.1), radius: 14, y: 6)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func atlasTitle(_ snapshot: DiningAtlasSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow("The places we’ve been")
            Text(placeCountLabel(snapshot))
                .font(BBTheme.display(26))
                .foregroundStyle(BBTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var routeKey: some View {
        HStack(spacing: 6) {
            Circle().fill(BBTheme.oxblood).frame(width: 7, height: 7)
            Text("FIRST VISITS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(BBTheme.ink.opacity(0.66))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pins are ordered by first visit")
    }

    @ViewBuilder
    private func stopCard(_ snapshot: DiningAtlasSnapshot) -> some View {
        if let stop = selectedStop(in: snapshot) {
            NavigationLink(value: AppRoute.location(stop.locationID)) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow("Stop \(stop.order) · \(stop.firstVisitDate.formatted(.dateTime.month(.abbreviated).year()))")
                        HStack(spacing: 7) {
                            Text(stop.name)
                                .font(BBTheme.display(23))
                                .lineLimit(1)
                            if stop.isClosed {
                                Text("CLOSED")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: stop.category.symbol)
                            Text(stop.city ?? stop.category.shortTitle)
                            Text("·")
                            Text(stop.visitCount == 1 ? "1 visit" : "\(stop.visitCount) visits")
                            if let reaction = stop.latestReaction {
                                Text("·")
                                Image(systemName: reaction.symbol)
                                    .foregroundStyle(BBTheme.oxblood)
                                    .accessibilityLabel(reaction.rawValue)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.headline)
                        .foregroundStyle(BBTheme.oxblood)
                }
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(BBTheme.paper.opacity(0.97))
            .overlay(alignment: .top) { Rectangle().fill(BBTheme.ink.opacity(0.16)).frame(height: 1) }
            .id(stop.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func emptyAtlas(title: String, message: String, symbol: String) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 72)
                ZStack {
                    Circle().stroke(BBTheme.oxblood.opacity(0.22), lineWidth: 1).frame(width: 118, height: 118)
                    Circle().stroke(BBTheme.oxblood.opacity(0.12), lineWidth: 1).frame(width: 82, height: 82)
                    Image(systemName: symbol)
                        .font(.system(size: 39, weight: .light))
                        .foregroundStyle(BBTheme.oxblood)
                }
                VStack(spacing: 10) {
                    Text(title)
                        .font(BBTheme.display(25))
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private func selectDefaultStop(from snapshot: DiningAtlasSnapshot) {
        guard !snapshot.stops.contains(where: { $0.id == selectedStopID }) else { return }
        selectedStopID = snapshot.stops.last?.id
        position = .automatic
    }

    private func selectedStop(in snapshot: DiningAtlasSnapshot) -> DiningAtlasStop? {
        snapshot.stops.first { $0.id == selectedStopID } ?? snapshot.stops.last
    }

    private func placeCountLabel(_ snapshot: DiningAtlasSnapshot) -> String {
        let count = snapshot.loggedPlaceCount
        return count == 1 ? "1 place on the record" : "\(count) places on the record"
    }

    private func headerDetail(_ snapshot: DiningAtlasSnapshot) -> String {
        let mapped = "Numbered in the order you first ate there. The dotted line traces your discoveries."
        guard snapshot.unmappedPlaceCount > 0 else { return mapped }
        let noun = snapshot.unmappedPlaceCount == 1 ? "place needs" : "places need"
        return "\(mapped) \(snapshot.unmappedPlaceCount) \(noun) a map location."
    }
}

private struct DiningAtlasPin: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let number: Int
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .top) {
            DiningAtlasPinShape()
                .fill(isSelected ? BBTheme.oxblood : BBTheme.paper)
            DiningAtlasPinShape()
                .stroke(BBTheme.oxblood, lineWidth: isSelected ? 2 : 1.5)
            Text("\(number)")
                .font(.system(size: number > 99 ? 10 : 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(isSelected ? BBTheme.cream : BBTheme.oxblood)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 25, height: 25)
                .padding(.top, 4)
        }
        .frame(width: isSelected ? 42 : 36, height: isSelected ? 49 : 43)
        .shadow(color: BBTheme.ink.opacity(isSelected ? 0.24 : 0.14), radius: isSelected ? 7 : 4, y: 3)
        .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.18), value: isSelected)
    }
}

private struct DiningAtlasPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let headRadius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: headRadius)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: headRadius),
            control1: CGPoint(x: rect.midX - rect.width * 0.18, y: rect.maxY * 0.82),
            control2: CGPoint(x: rect.minX, y: rect.height * 0.62)
        )
        path.addArc(
            center: center,
            radius: headRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.height * 0.62),
            control2: CGPoint(x: rect.midX + rect.width * 0.18, y: rect.maxY * 0.82)
        )
        path.closeSubpath()
        return path
    }
}
