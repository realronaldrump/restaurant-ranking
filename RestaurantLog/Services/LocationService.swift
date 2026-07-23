import CoreLocation
import MapKit
import Observation

struct PlaceCandidate: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String?
    let city: String?
    let latitude: Double
    let longitude: Double
    let phone: String?
    let url: URL?
    let suggestedCategory: DiningCategory
    let cuisines: [String]

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

enum LocationQualityPolicy {
    static let maximumAge: TimeInterval = 60
    static let maximumNearbyHorizontalAccuracy: CLLocationAccuracy = 200
    static let maximumVisitHorizontalAccuracy: CLLocationAccuracy = 100
    static let maximumVisitDistanceFromEstablishment: CLLocationDistance = 250

    static func usableLocation(
        _ location: CLLocation?,
        asOf now: Date = .now,
        maximumHorizontalAccuracy: CLLocationAccuracy = maximumNearbyHorizontalAccuracy
    ) -> CLLocation? {
        guard let location,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maximumHorizontalAccuracy,
              abs(now.timeIntervalSince(location.timestamp)) <= maximumAge else { return nil }
        return location
    }

    static func visitCoordinate(
        from location: CLLocation?,
        near establishmentCoordinate: CLLocationCoordinate2D?,
        asOf now: Date = .now
    ) -> CLLocationCoordinate2D? {
        guard let establishmentCoordinate,
              CLLocationCoordinate2DIsValid(establishmentCoordinate),
              let location = usableLocation(
                location,
                asOf: now,
                maximumHorizontalAccuracy: maximumVisitHorizontalAccuracy
              ) else { return nil }
        let establishment = CLLocation(
            latitude: establishmentCoordinate.latitude,
            longitude: establishmentCoordinate.longitude
        )
        guard location.distance(from: establishment) <= maximumVisitDistanceFromEstablishment else { return nil }
        return location.coordinate
    }
}

enum LocationSearchPolicy {
    static let diningCategories: [MKPointOfInterestCategory] = [
        .restaurant,
        .cafe,
        .bakery,
        .brewery,
        .nightlife,
        .winery
    ]

    static func nearbyRequest(
        around coordinate: CLLocationCoordinate2D,
        radius: CLLocationDistance
    ) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: diningCategories)
        return request
    }

    static func textRequest(
        _ query: String,
        around coordinate: CLLocationCoordinate2D?,
        radius: CLLocationDistance
    ) -> MKLocalSearch.Request? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = value
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2
            )
        }
        request.resultTypes = .pointOfInterest
        return request
    }

    static func textSearchCenter(
        explicit coordinate: CLLocationCoordinate2D?,
        current _: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        // Nearby suggestions already use the current location. A typed search stays broad
        // unless a caller explicitly supplies a coordinate (for example, photo backfill).
        coordinate
    }

    static func userMessage(for error: Error) -> String? {
        let error = error as NSError
        if error.domain == MKErrorDomain,
           let rawCode = UInt(exactly: error.code),
           let code = MKError.Code(rawValue: rawCode) {
            switch code {
            case .placemarkNotFound:
                return nil
            case .loadingThrottled:
                return "Map search is busy right now. Wait a moment and try again."
            case .unknown, .serverFailure, .directionsNotFound, .decodingFailed:
                return "Map search is temporarily unavailable. Try again."
            @unknown default:
                return "Map search couldn't be completed. Try again."
            }
        }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorNotConnectedToInternet {
            return "You're offline. Connect to the internet and try again."
        }
        return "Map search couldn't be completed. Try again."
    }
}

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var activeSearchCount = 0

    private(set) var authorization: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var currentLocation: CLLocation?
    private(set) var nearby: [PlaceCandidate] = []
    private(set) var isSearching = false
    var errorMessage: String?

    override init() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var usableCurrentLocation: CLLocation? {
        LocationQualityPolicy.usableLocation(currentLocation)
    }

    func currentVisitCoordinate(
        near establishmentCoordinate: (latitude: Double, longitude: Double)?
    ) -> (Double, Double)? {
        let coordinate = establishmentCoordinate.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        return LocationQualityPolicy.visitCoordinate(from: currentLocation, near: coordinate).map {
            ($0.latitude, $0.longitude)
        }
    }

    func requestNearby() {
        switch authorization {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            errorMessage = nil
            currentLocation = nil
            nearby = []
            manager.requestLocation()
        case .denied, .restricted:
            currentLocation = nil
            nearby = []
            errorMessage = "Location is off. You can still search."
        @unknown default: break
        }
    }

    func search(
        _ query: String,
        around coordinate: CLLocationCoordinate2D? = nil,
        radius: CLLocationDistance = 9_000
    ) async -> [PlaceCandidate] {
        let center = LocationSearchPolicy.textSearchCenter(
            explicit: coordinate,
            current: usableCurrentLocation?.coordinate
        )
        guard let request = LocationSearchPolicy.textRequest(query, around: center, radius: radius) else {
            return []
        }
        do {
            return try await results(from: MKLocalSearch(request: request), around: center, radius: radius)
        } catch {
            return []
        }
    }

    func searchNearby(
        around coordinate: CLLocationCoordinate2D,
        radius: CLLocationDistance = 9_000
    ) async -> [PlaceCandidate] {
        guard CLLocationCoordinate2DIsValid(coordinate), radius > 0 else { return [] }
        let request = LocationSearchPolicy.nearbyRequest(around: coordinate, radius: radius)
        do {
            return try await results(from: MKLocalSearch(request: request), around: coordinate, radius: radius)
        } catch {
            return []
        }
    }

    func refreshNearby() async {
        guard let center = usableCurrentLocation?.coordinate else {
            nearby = []
            return
        }
        errorMessage = nil
        let request = LocationSearchPolicy.nearbyRequest(around: center, radius: 9_000)
        do {
            let values = try await results(from: MKLocalSearch(request: request), around: center, radius: 9_000)
            guard !Task.isCancelled else { return }
            nearby = values
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            nearby = []
            errorMessage = LocationSearchPolicy.userMessage(for: error)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            authorization = status
            accuracyAuthorization = accuracy
            currentLocation = nil
            nearby = []
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                errorMessage = nil
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.reversed().compactMap { LocationQualityPolicy.usableLocation($0) }.first
        Task { @MainActor in
            guard let latest else {
                currentLocation = nil
                nearby = []
                errorMessage = "Your current location was too old or imprecise. Try again, or search instead."
                return
            }
            currentLocation = latest
            errorMessage = nil
            await refreshNearby()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            currentLocation = nil
            nearby = []
            let code = (error as? CLError)?.code
            errorMessage = switch code {
            case .denied: "Location is off. You can still search."
            case .network: "Your location is temporarily unavailable. Try again, or search instead."
            default: "Couldn't get your current location. Try again, or search instead."
            }
        }
    }

    private func results(
        from search: MKLocalSearch,
        around center: CLLocationCoordinate2D?,
        radius: CLLocationDistance
    ) async throws -> [PlaceCandidate] {
        activeSearchCount += 1
        isSearching = true
        defer {
            activeSearchCount = max(0, activeSearchCount - 1)
            isSearching = activeSearchCount > 0
        }

        try Task.checkCancellation()
        let response = try await search.start()
        try Task.checkCancellation()
        let values = response.mapItems.compactMap(Self.candidate(from:))
        guard let center else { return Array(values.prefix(30)) }

        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let filtered = values.filter { candidate in
            origin.distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)) <= radius
        }.sorted { lhs, rhs in
            origin.distance(from: CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)) <
            origin.distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
        }
        return Array(filtered.prefix(30))
    }

    private static func candidate(from item: MKMapItem) -> PlaceCandidate? {
        guard let name = item.name, !name.isEmpty else { return nil }
        let placemark = item.placemark
        let address = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let fullAddress = ([address] + [placemark.locality, placemark.administrativeArea].compactMap { $0 })
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let cuisineHints = inferredCuisines(name: name)
        return PlaceCandidate(
            id: "\(name)-\(placemark.coordinate.latitude)-\(placemark.coordinate.longitude)",
            name: name,
            address: fullAddress.isEmpty ? nil : fullAddress,
            city: placemark.locality,
            latitude: placemark.coordinate.latitude,
            longitude: placemark.coordinate.longitude,
            phone: item.phoneNumber,
            url: item.url,
            suggestedCategory: DiningCategory.suggested(for: name, cuisine: cuisineHints.first),
            cuisines: cuisineHints
        )
    }

    private static func inferredCuisines(name: String) -> [String] {
        let value = name.lowercased()
        let hints: [(String, String)] = [
            ("taco", "Mexican"), ("ramen", "Japanese"), ("sushi", "Japanese"), ("pho", "Vietnamese"),
            ("thai", "Thai"), ("pizza", "Pizza"), ("bbq", "Barbecue"), ("bakery", "Bakery"),
            ("coffee", "Coffee"), ("gelato", "Italian"), ("india", "Indian"), ("burger", "Burgers")
        ]
        return hints.compactMap { value.contains($0.0) ? $0.1 : nil }.uniqued()
    }
}
