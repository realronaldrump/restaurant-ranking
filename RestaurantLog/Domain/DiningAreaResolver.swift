import Foundation

struct DiningAreaEvidence: Sendable {
    let id: UUID
    let city: String?
    let restaurantName: String
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let sourceIdentifier: String?
    let outingCount: Int
}

struct ResolvedDiningArea: Equatable, Sendable {
    let id: String
    let name: String
}

/// Reconciles the human-readable locality labels that arrive from Maps,
/// imports, backups, and manual entry without changing the saved restaurants.
///
/// Exact spelling is not treated as geographic identity. The resolver removes
/// harmless formatting differences, understands optional region qualifiers,
/// and recognizes a small set of administrative long forms. If one locality
/// has multiple explicit regions, its bare form remains separate rather than
/// being guessed into the wrong place.
enum DiningAreaResolver {
    private struct ParsedEvidence {
        let evidence: DiningAreaEvidence
        let displayName: String
        let localityKey: String
        let regionKey: String?
    }

    private struct DisplayCandidate {
        let name: String
        let isQualified: Bool
        let trustedSourceCount: Int
        let richEvidenceCount: Int
        let outingCount: Int
        let occurrenceCount: Int
        let localityWordCount: Int
    }

    private struct LocalityPair: Hashable {
        let first: String
        let second: String

        init(_ lhs: String, _ rhs: String) {
            first = min(lhs, rhs)
            second = max(lhs, rhs)
        }
    }

    static func resolve(_ evidence: [DiningAreaEvidence]) -> [UUID: ResolvedDiningArea] {
        let parsed = evidence.compactMap(parse)
        let byLocality = Dictionary(grouping: parsed, by: \.localityKey)
        let localityKeys = byLocality.keys.sorted()
        var parents = Dictionary(uniqueKeysWithValues: localityKeys.map { ($0, $0) })

        func root(of key: String) -> String {
            var value = key
            while let parent = parents[value], parent != value { value = parent }
            return value
        }

        func regionSet(for key: String) -> Set<String> {
            Set((byLocality[key] ?? []).compactMap(\.regionKey))
        }

        // Formatting and administrative aliases already share a locality key.
        // Build typo candidates from repeated restaurant identities so this
        // stays near-linear for logs containing hundreds or thousands of areas.
        var typoCandidates = Set<LocalityPair>()
        let byRestaurant = Dictionary(grouping: parsed) {
            lookupKey($0.evidence.restaurantName)
        }
        for (restaurantKey, restaurantEntries) in byRestaurant where !restaurantKey.isEmpty {
            let keys = Array(Set(restaurantEntries.map(\.localityKey))).sorted()
            for (offset, firstKey) in keys.enumerated() {
                for secondKey in keys.dropFirst(offset + 1)
                where abs(firstKey.count - secondKey.count) <= 2 {
                    typoCandidates.insert(LocalityPair(firstKey, secondKey))
                }
            }
        }
        for pair in typoCandidates.sorted(by: {
            $0.first == $1.first ? $0.second < $1.second : $0.first < $1.first
        }) {
            guard areMinorSpellingVariants(pair.first, pair.second),
                  regionsAreCompatible(regionSet(for: pair.first), regionSet(for: pair.second)),
                  placesCorroborate(byLocality[pair.first] ?? [], byLocality[pair.second] ?? []) else {
                continue
            }
            let firstRoot = root(of: pair.first)
            let secondRoot = root(of: pair.second)
            if firstRoot != secondRoot { parents[secondRoot] = firstRoot }
        }

        let clusteredKeys = Dictionary(grouping: localityKeys, by: { root(of: $0) })
        var result: [UUID: ResolvedDiningArea] = [:]
        for keys in clusteredKeys.values {
            let entries = keys.flatMap { byLocality[$0] ?? [] }
            let explicitRegions = Set(entries.compactMap(\.regionKey))

            if explicitRegions.count <= 1 {
                assign(entries, fallbackLocalityKey: keys[0], to: &result)
                continue
            }

            // `Springfield` cannot safely choose between explicit Illinois and
            // Missouri groups. Qualified records still reconcile with matching
            // qualified records; the unqualified residue stays independent.
            for (region, regionEntries) in Dictionary(
                grouping: entries,
                by: { $0.regionKey ?? "" }
            ) {
                assign(
                    regionEntries,
                    fallbackLocalityKey: "\(keys[0])|\(region.isEmpty ? "unspecified" : region)",
                    to: &result
                )
            }
        }
        return result
    }

    @MainActor
    static func resolve(locations: [RestaurantLocation]) -> [UUID: ResolvedDiningArea] {
        resolve(locations.map { location in
            let coordinate = location.coordinate
            return DiningAreaEvidence(
                id: location.id,
                city: location.city,
                restaurantName: location.name,
                address: location.address,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude,
                sourceIdentifier: location.sourceIdentifier,
                outingCount: location.visitArray.count
            )
        })
    }

    static func lookupKey(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let words = folded.unicodeScalars.split { scalar in
            !CharacterSet.alphanumerics.contains(scalar)
        }
        return words.map(String.init).joined(separator: " ")
    }

    private static func parse(_ evidence: DiningAreaEvidence) -> ParsedEvidence? {
        guard let displayName = normalizedDisplayName(evidence.city) else { return nil }
        let parsedName = parsedAreaName(displayName)
        guard !parsedName.localityKey.isEmpty else { return nil }
        return ParsedEvidence(
            evidence: evidence,
            displayName: displayName,
            localityKey: parsedName.localityKey,
            regionKey: parsedName.regionKey
        )
    }

    private static func parsedAreaName(_ displayName: String) -> (localityKey: String, regionKey: String?) {
        let commaParts = displayName.split(separator: ",", omittingEmptySubsequences: true)
            .map { normalizedDisplayName(String($0)) ?? "" }
            .filter { !$0.isEmpty }
        var locality = commaParts.first ?? displayName
        var region: String?

        if commaParts.count > 1 {
            var qualifiers = Array(commaParts.dropFirst())
            if qualifiers.count > 1, isUnitedStatesCountryName(qualifiers.last ?? "") {
                qualifiers.removeLast()
            }
            region = qualifiers.last.map(canonicalRegionKey)
        } else {
            let words = locality.split(separator: " ").map(String.init)
            if words.count > 1,
               let candidate = words.last,
               isRecognizedUnseparatedRegion(candidate) {
                region = canonicalRegionKey(candidate)
                locality = words.dropLast().joined(separator: " ")
            }
        }

        return (semanticLocalityKey(locality), nonblank(region))
    }

    private static func semanticLocalityKey(_ value: String) -> String {
        var words = lookupKey(value).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "" }

        let firstWordAliases = ["st": "saint", "ft": "fort", "mt": "mount"]
        if let alias = firstWordAliases[words[0]] { words[0] = alias }

        let leadingAdministrativeForms = [
            ["city", "of"], ["town", "of"], ["village", "of"],
            ["borough", "of"], ["municipality", "of"]
        ]
        for prefix in leadingAdministrativeForms where words.starts(with: prefix) {
            words.removeFirst(prefix.count)
            break
        }

        let trailingAdministrativeForms = [
            ["historic", "district"], ["historical", "district"],
            ["census", "designated", "place"]
        ]
        var strippedSuffix = true
        while strippedSuffix {
            strippedSuffix = false
            for suffix in trailingAdministrativeForms
            where words.count > suffix.count && words.suffix(suffix.count).elementsEqual(suffix) {
                words.removeLast(suffix.count)
                strippedSuffix = true
                break
            }
        }
        return words.joined(separator: " ")
    }

    private static func assign(
        _ entries: [ParsedEvidence],
        fallbackLocalityKey: String,
        to result: inout [UUID: ResolvedDiningArea]
    ) {
        guard !entries.isEmpty else { return }
        let name = preferredDisplayName(in: entries)
        let parsedName = parsedAreaName(name)
        let locality = nonblank(parsedName.localityKey) ?? fallbackLocalityKey
        let explicitRegions = Set(entries.compactMap(\.regionKey))
        let region = explicitRegions.count == 1 ? explicitRegions.first : nil
        let area = ResolvedDiningArea(
            id: "area:\(locality)|\(region ?? "unspecified")",
            name: name
        )
        for entry in entries { result[entry.evidence.id] = area }
    }

    private static func preferredDisplayName(in entries: [ParsedEvidence]) -> String {
        let candidates = Dictionary(grouping: entries, by: \.displayName).map { name, values in
            let parsedName = parsedAreaName(name)
            return DisplayCandidate(
                name: name,
                isQualified: parsedName.regionKey != nil,
                trustedSourceCount: values.filter { isTrustedSource($0.evidence.sourceIdentifier) }.count,
                richEvidenceCount: values.filter {
                    nonblank($0.evidence.address) != nil ||
                        ($0.evidence.latitude != nil && $0.evidence.longitude != nil)
                }.count,
                outingCount: values.reduce(0) { $0 + max(0, $1.evidence.outingCount) },
                occurrenceCount: values.count,
                localityWordCount: lookupKey(name).split(separator: " ").count
            )
        }
        return candidates.sorted(by: displayCandidateComesBefore).first?.name
            ?? entries[0].displayName
    }

    private static func displayCandidateComesBefore(_ lhs: DisplayCandidate, _ rhs: DisplayCandidate) -> Bool {
        if lhs.isQualified != rhs.isQualified { return lhs.isQualified }
        if lhs.trustedSourceCount != rhs.trustedSourceCount { return lhs.trustedSourceCount > rhs.trustedSourceCount }
        if lhs.richEvidenceCount != rhs.richEvidenceCount { return lhs.richEvidenceCount > rhs.richEvidenceCount }
        if lhs.localityWordCount != rhs.localityWordCount { return lhs.localityWordCount > rhs.localityWordCount }
        if lhs.outingCount != rhs.outingCount { return lhs.outingCount > rhs.outingCount }
        if lhs.occurrenceCount != rhs.occurrenceCount { return lhs.occurrenceCount > rhs.occurrenceCount }
        if lhs.name.count != rhs.name.count { return lhs.name.count < rhs.name.count }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func isTrustedSource(_ sourceIdentifier: String?) -> Bool {
        guard let source = nonblank(sourceIdentifier) else { return false }
        return !source.lowercased().hasPrefix("beli:")
    }

    private static func regionsAreCompatible(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        lhs.isEmpty || rhs.isEmpty || !lhs.isDisjoint(with: rhs)
    }

    private static func placesCorroborate(_ lhs: [ParsedEvidence], _ rhs: [ParsedEvidence]) -> Bool {
        for first in lhs {
            for second in rhs {
                let sameRestaurant = lookupKey(first.evidence.restaurantName)
                    == lookupKey(second.evidence.restaurantName)
                guard sameRestaurant else { continue }

                let firstSource = nonblank(first.evidence.sourceIdentifier).map(lookupKey)
                let secondSource = nonblank(second.evidence.sourceIdentifier).map(lookupKey)
                if let firstSource, firstSource == secondSource { return true }

                let firstAddress = nonblank(first.evidence.address).map(lookupKey)
                let secondAddress = nonblank(second.evidence.address).map(lookupKey)
                if let firstAddress, firstAddress == secondAddress { return true }

                if coordinateDistance(first.evidence, second.evidence).map({ $0 <= 250 }) == true {
                    return true
                }

            }
        }
        return false
    }

    private static func coordinateDistance(
        _ lhs: DiningAreaEvidence,
        _ rhs: DiningAreaEvidence
    ) -> Double? {
        guard let lhsLatitude = lhs.latitude, let lhsLongitude = lhs.longitude,
              let rhsLatitude = rhs.latitude, let rhsLongitude = rhs.longitude,
              StoredCoordinatePolicy.isValid(latitude: lhsLatitude, longitude: lhsLongitude),
              StoredCoordinatePolicy.isValid(latitude: rhsLatitude, longitude: rhsLongitude) else {
            return nil
        }
        let degreesToRadians = Double.pi / 180
        let latitudeDelta = (rhsLatitude - lhsLatitude) * degreesToRadians
        let longitudeDelta = (rhsLongitude - lhsLongitude) * degreesToRadians
        let firstLatitude = lhsLatitude * degreesToRadians
        let secondLatitude = rhsLatitude * degreesToRadians
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private static func areMinorSpellingVariants(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs, min(lhs.count, rhs.count) >= 4 else { return false }
        return editDistance(lhs, rhs, stoppingAfter: 2) <= 2
    }

    private static func editDistance(_ lhs: String, _ rhs: String, stoppingAfter limit: Int) -> Int {
        let first = Array(lhs)
        let second = Array(rhs)
        if abs(first.count - second.count) > limit { return limit + 1 }
        var previous = Array(0...second.count)
        for (row, firstCharacter) in first.enumerated() {
            var current = [row + 1]
            var rowMinimum = row + 1
            for (column, secondCharacter) in second.enumerated() {
                let substitution = previous[column] + (firstCharacter == secondCharacter ? 0 : 1)
                let insertion = current[column] + 1
                let deletion = previous[column + 1] + 1
                let value = min(substitution, insertion, deletion)
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous.last ?? limit + 1
    }

    private static func normalizedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let words = value.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func canonicalRegionKey(_ value: String) -> String {
        let key = lookupKey(value)
        return unitedStatesRegions[key]
            ?? unitedStatesRegions[key.split(separator: " ").joined()]
            ?? key
    }

    private static func isRecognizedUnseparatedRegion(_ value: String) -> Bool {
        let key = lookupKey(value)
        return unitedStatesRegions[key] != nil
            || unitedStatesRegions[key.split(separator: " ").joined()] != nil
    }

    private static func isUnitedStatesCountryName(_ value: String) -> Bool {
        ["united states", "united states of america", "usa", "us"].contains(lookupKey(value))
    }

    private static let unitedStatesRegions: [String: String] = {
        let pairs = [
            ("AL", "Alabama"), ("AK", "Alaska"), ("AZ", "Arizona"), ("AR", "Arkansas"),
            ("CA", "California"), ("CO", "Colorado"), ("CT", "Connecticut"), ("DE", "Delaware"),
            ("FL", "Florida"), ("GA", "Georgia"), ("HI", "Hawaii"), ("ID", "Idaho"),
            ("IL", "Illinois"), ("IN", "Indiana"), ("IA", "Iowa"), ("KS", "Kansas"),
            ("KY", "Kentucky"), ("LA", "Louisiana"), ("ME", "Maine"), ("MD", "Maryland"),
            ("MA", "Massachusetts"), ("MI", "Michigan"), ("MN", "Minnesota"), ("MS", "Mississippi"),
            ("MO", "Missouri"), ("MT", "Montana"), ("NE", "Nebraska"), ("NV", "Nevada"),
            ("NH", "New Hampshire"), ("NJ", "New Jersey"), ("NM", "New Mexico"), ("NY", "New York"),
            ("NC", "North Carolina"), ("ND", "North Dakota"), ("OH", "Ohio"), ("OK", "Oklahoma"),
            ("OR", "Oregon"), ("PA", "Pennsylvania"), ("RI", "Rhode Island"), ("SC", "South Carolina"),
            ("SD", "South Dakota"), ("TN", "Tennessee"), ("TX", "Texas"), ("UT", "Utah"),
            ("VT", "Vermont"), ("VA", "Virginia"), ("WA", "Washington"), ("WV", "West Virginia"),
            ("WI", "Wisconsin"), ("WY", "Wyoming"), ("DC", "District of Columbia")
        ]
        var values: [String: String] = [:]
        for (abbreviation, name) in pairs {
            values[lookupKey(abbreviation)] = abbreviation.lowercased()
            values[lookupKey(name)] = abbreviation.lowercased()
        }
        return values
    }()
}
