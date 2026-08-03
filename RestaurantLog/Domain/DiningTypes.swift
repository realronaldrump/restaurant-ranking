import Foundation

enum DiningTimeZoneOffset {
    static func seconds(from value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed == "Z" { return 0 }

        let characters = Array(trimmed)
        guard characters.count == 6 || characters.count == 5,
              characters[0] == "+" || characters[0] == "-" else { return nil }
        let separatorIndex = characters.count == 6 ? 3 : 0
        if characters.count == 6 && characters[separatorIndex] != ":" { return nil }

        let hourStart = 1
        let minuteStart = characters.count == 6 ? 4 : 3
        guard let hours = Int(String(characters[hourStart..<(hourStart + 2)])),
              let minutes = Int(String(characters[minuteStart..<(minuteStart + 2)])),
              hours <= 23, minutes <= 59 else { return nil }
        let total = hours * 60 * 60 + minutes * 60
        return characters[0] == "-" ? -total : total
    }
}

enum DiningDateContext {
    static func timeZone(offsetSeconds: Int?) -> TimeZone? {
        guard let offsetSeconds, abs(offsetSeconds) <= 24 * 60 * 60 else { return nil }
        return TimeZone(secondsFromGMT: offsetSeconds)
    }

    static func currentOffset(for date: Date) -> Int {
        TimeZone.autoupdatingCurrent.secondsFromGMT(for: date)
    }

    static func calendar(offsetSeconds: Int?) -> Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let timeZone = timeZone(offsetSeconds: offsetSeconds) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    static func format(
        _ date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        offsetSeconds: Int? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar(offsetSeconds: offsetSeconds)
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        if let timeZone = timeZone(offsetSeconds: offsetSeconds) {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date)
    }

    static func year(of date: Date, offsetSeconds: Int?) -> Int {
        calendar(offsetSeconds: offsetSeconds).component(.year, from: date)
    }

    static func stableDayKey(for date: Date, offsetSeconds: Int?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(offsetSeconds: offsetSeconds) ?? .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func isSameCalendarDay(
        _ lhs: Date,
        lhsOffsetSeconds: Int?,
        _ rhs: Date,
        rhsOffsetSeconds: Int?
    ) -> Bool {
        stableDayKey(for: lhs, offsetSeconds: lhsOffsetSeconds)
            == stableDayKey(for: rhs, offsetSeconds: rhsOffsetSeconds)
    }

    static func formatMonthYear(_ date: Date, offsetSeconds: Int?) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar(offsetSeconds: offsetSeconds)
        formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
        if let timeZone = timeZone(offsetSeconds: offsetSeconds) {
            formatter.timeZone = timeZone
        }
        return formatter.string(from: date)
    }
}

enum DiningCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case fullService = "Full-Service Restaurants"
    case counterService = "Counter Service and Fast Food"
    case coffeeTea = "Coffee and Tea"
    case bakeries = "Bakeries"
    case barsBreweries = "Bars and Breweries"
    case dessert = "Dessert and Ice Cream"
    case trucksStands = "Food Trucks and Stands"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .fullService: "Full Service"
        case .counterService: "Counter Service"
        case .coffeeTea: "Coffee & Tea"
        case .bakeries: "Bakeries"
        case .barsBreweries: "Bars & Breweries"
        case .dessert: "Dessert"
        case .trucksStands: "Trucks & Stands"
        }
    }

    var symbol: String {
        switch self {
        case .fullService: "fork.knife"
        case .counterService: "takeoutbag.and.cup.and.straw"
        case .coffeeTea: "cup.and.saucer.fill"
        case .bakeries: "birthday.cake.fill"
        case .barsBreweries: "wineglass.fill"
        case .dessert: "snowflake"
        case .trucksStands: "truck.box.fill"
        }
    }

    static func suggested(for name: String, cuisine: String? = nil) -> DiningCategory {
        let value = "\(name) \(cuisine ?? "")".lowercased()
        if ["coffee", "cafe", "café", "tea", "roast"].contains(where: value.contains) { return .coffeeTea }
        if ["bakery", "bake", "bread", "pastry", "bagel", "donut"].contains(where: value.contains) { return .bakeries }
        if ["bar", "brew", "taproom", "tavern", "pub", "cocktail"].contains(where: value.contains) { return .barsBreweries }
        if ["ice cream", "gelato", "dessert", "chocolate", "sweet"].contains(where: value.contains) { return .dessert }
        if ["truck", "stand", "cart", "market stall"].contains(where: value.contains) { return .trucksStands }
        if ["counter", "burger", "taco", "pizza", "sandwich", "fast"].contains(where: value.contains) { return .counterService }
        return .fullService
    }
}

enum Reaction: String, CaseIterable, Codable, Identifiable, Sendable {
    case loved = "Loved It"
    case liked = "Liked It"
    case fine = "It Was Fine"
    case notForMe = "Not For Me"

    var id: String { rawValue }

    /// Display name. Deliberately separate from `rawValue`, which is persisted in
    /// Core Data and in sync records and must not change.
    var title: String {
        switch self {
        case .loved: "Loved it"
        case .liked: "Liked it"
        case .fine: "It was fine"
        case .notForMe: "Not for me"
        }
    }

    var anchor: Double {
        switch self {
        case .loved: 85
        case .liked: 72
        case .fine: 55
        case .notForMe: 35
        }
    }
    var symbol: String {
        switch self {
        case .loved: "heart.fill"
        case .liked: "hand.thumbsup.fill"
        case .fine: "equal.circle.fill"
        case .notForMe: "hand.thumbsdown.fill"
        }
    }
    var compactTitle: String {
        switch self {
        case .loved: "Loved"
        case .liked: "Liked"
        case .fine: "Fine"
        case .notForMe: "Not for me"
        }
    }
}

/// The mascot family that owns a social sticker.
///
/// The raw values are persisted with sticker records. Keep `coon` as the
/// default so records written before Mr. Bubbles was introduced continue to
/// render exactly as they did before.
enum StickerMascot: String, CaseIterable, Codable, Identifiable, Sendable {
    case coon
    case mrBubbles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coon: "Coon"
        case .mrBubbles: "Mr. Bubbles"
        }
    }

    var assetPrefix: String {
        switch self {
        case .coon: "Coon"
        case .mrBubbles: "MrBubbles"
        }
    }
}

/// A playful, social response to somebody else's diner entry.
///
/// These are intentionally separate from `Reaction`: a diner's own reaction is
/// ranking evidence, while a Coon reaction is social decoration and must never
/// influence a restaurant's score.
enum CoonReaction: String, CaseIterable, Codable, Identifiable, Sendable {
    case runItBack
    case unexpectedlyWonderful
    case merelyFine
    case absolutelyNot
    case topTableMaterial
    case orderItAgain
    case needsARematch
    case culinaryBetrayal
    case noNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runItBack: "Run It Back"
        case .unexpectedlyWonderful: "Unexpectedly Wonderful"
        case .merelyFine: "Merely Fine"
        case .absolutelyNot: "Absolutely Not"
        case .topTableMaterial: "Top-Table Material"
        case .orderItAgain: "Order It Again"
        case .needsARematch: "Needs a Rematch"
        case .culinaryBetrayal: "Culinary Betrayal"
        case .noNotes: "No Notes"
        }
    }

    private var assetStem: String {
        switch self {
        case .runItBack: "RunItBack"
        case .unexpectedlyWonderful: "UnexpectedlyWonderful"
        case .merelyFine: "MerelyFine"
        case .absolutelyNot: "AbsolutelyNot"
        case .topTableMaterial: "TopTableMaterial"
        case .orderItAgain: "OrderItAgain"
        case .needsARematch: "NeedsARematch"
        case .culinaryBetrayal: "CulinaryBetrayal"
        case .noNotes: "NoNotes"
        }
    }

    /// Legacy Coon asset lookup retained for callers that only know a reaction.
    var assetName: String { assetName(for: .coon) }

    func assetName(for mascot: StickerMascot) -> String {
        "\(mascot.assetPrefix)\(assetStem)"
    }
}

enum VisitParticipationStatus: String, Codable, Sendable {
    case pending
    case attended
    case declined
    case notThere
}

enum VisitDateKnowledge: String, Codable, Sendable {
    case known
    case unknown
}

enum VisitType: String, CaseIterable, Codable, Identifiable, Sendable {
    case meal = "Meal"
    case drinks = "Drinks"
    case coffee = "Coffee"
    case dessert = "Dessert"
    case takeout = "Takeout"
    case quickStop = "Quick Stop"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .meal: "fork.knife"
        case .drinks: "wineglass"
        case .coffee: "cup.and.saucer"
        case .dessert: "birthday.cake"
        case .takeout: "takeoutbag.and.cup.and.straw"
        case .quickStop: "figure.walk.motion"
        }
    }
}

enum DishRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case entree = "Entrée"
    case shared = "Shared"
    case appetizer = "Appetizer"
    case side = "Side"
    case drink = "Drink"
    case dessert = "Dessert"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .entree: "fork.knife"
        case .shared: "person.2.fill"
        case .appetizer: "takeoutbag.and.cup.and.straw"
        case .side: "square.split.2x1"
        case .drink: "wineglass"
        case .dessert: "birthday.cake"
        }
    }
    var weight: Double {
        switch self {
        case .entree: 1
        case .shared: 0.85
        case .appetizer: 0.65
        case .side: 0.45
        case .drink: 0.4
        case .dessert: 0.65
        }
    }
}

enum Occasion: String, CaseIterable, Codable, Identifiable, Sendable {
    case everyday = "Just Because"
    case dateNight = "Date Night"
    case birthday = "Birthday"
    case celebration = "Celebration"
    case work = "Work"
    case travel = "Travel"
    var id: String { rawValue }
}

enum ComparisonOutcome: String, Codable, Sendable {
    case a, b, tie, skipped
}

struct ScoreAnchor: Identifiable, Hashable {
    let score: Double
    let statement: String
    var id: Double { score }

    static let ladder: [ScoreAnchor] = [
        .init(score: 95, statement: "I would plan a trip around it."),
        .init(score: 85, statement: "I am excited to go back."),
        .init(score: 75, statement: "I would happily go back."),
        .init(score: 65, statement: "I would go if it came up."),
        .init(score: 50, statement: "I could take it or leave it."),
        .init(score: 35, statement: "I would usually pick somewhere else."),
        .init(score: 15, statement: "I would avoid going back.")
    ]
}
