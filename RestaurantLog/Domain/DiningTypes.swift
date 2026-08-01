import Foundation

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

    var assetName: String {
        switch self {
        case .runItBack: "CoonRunItBack"
        case .unexpectedlyWonderful: "CoonUnexpectedlyWonderful"
        case .merelyFine: "CoonMerelyFine"
        case .absolutelyNot: "CoonAbsolutelyNot"
        case .topTableMaterial: "CoonTopTableMaterial"
        case .orderItAgain: "CoonOrderItAgain"
        case .needsARematch: "CoonNeedsARematch"
        case .culinaryBetrayal: "CoonCulinaryBetrayal"
        case .noNotes: "CoonNoNotes"
        }
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
