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

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()

    private(set) var authorization: CLAuthorizationStatus
    private(set) var currentLocation: CLLocation?
    private(set) var nearby: [PlaceCandidate] = []
    private(set) var isSearching = false
    var errorMessage: String?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestNearby() {
        switch authorization {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: errorMessage = "Location is off. Search still works beautifully."
        @unknown default: break
        }
    }

    func search(_ query: String, around coordinate: CLLocationCoordinate2D? = nil, radius: CLLocationDistance = 9_000) async -> [PlaceCandidate] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = value.isEmpty ? "restaurant cafe bakery bar" : value
        let center = coordinate ?? currentLocation?.coordinate
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        }
        request.resultTypes = .pointOfInterest
        isSearching = true
        defer { isSearching = false }
        do {
            let response = try await MKLocalSearch(request: request).start()
            let values = response.mapItems.compactMap(Self.candidate(from:))
            let filtered: [PlaceCandidate]
            if let center, radius < 9_000 {
                let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
                filtered = values.filter { candidate in
                    origin.distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)) <= radius
                }.sorted { lhs, rhs in
                    origin.distance(from: CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)) <
                    origin.distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
                }
            } else if let center {
                let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
                filtered = values.sorted { lhs, rhs in
                    origin.distance(from: CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)) <
                    origin.distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
                }
            } else {
                filtered = values
            }
            return Array(filtered.prefix(30))
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func refreshNearby() async {
        nearby = await search("restaurant cafe bakery bar dessert")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways { manager.requestLocation() }
        Task { @MainActor in authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            currentLocation = latest
            await refreshNearby()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in errorMessage = error.localizedDescription }
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
