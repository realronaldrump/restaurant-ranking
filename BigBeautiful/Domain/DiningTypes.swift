import Foundation

enum DiningCategory: String, CaseIterable, Codable, Identifiable {
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

enum Reaction: String, CaseIterable, Codable, Identifiable {
    case loved = "Loved It"
    case liked = "Liked It"
    case fine = "It Was Fine"
    case notForMe = "Not For Me"

    var id: String { rawValue }
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
        case .notForMe: "arrow.uturn.backward.circle.fill"
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

enum VisitType: String, CaseIterable, Codable, Identifiable {
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

enum DishRole: String, CaseIterable, Codable, Identifiable {
    case entree = "Entrée"
    case shared = "Shared"
    case appetizer = "Appetizer"
    case side = "Side"
    case drink = "Drink"
    case dessert = "Dessert"
    var id: String { rawValue }
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

enum Occasion: String, CaseIterable, Codable, Identifiable {
    case everyday = "Just Because"
    case dateNight = "Date Night"
    case birthday = "Birthday"
    case celebration = "Celebration"
    case work = "Work"
    case travel = "Travel"
    var id: String { rawValue }
}

enum ComparisonOutcome: String, Codable {
    case a, b, tie, skipped
}

enum RankingScope: String, CaseIterable, Identifiable {
    case me = "Me"
    case partner = "Partner"
    case us = "Us"
    var id: String { rawValue }
}

struct ScoreAnchor: Identifiable, Hashable {
    let score: Double
    let statement: String
    var id: Double { score }

    static let ladder: [ScoreAnchor] = [
        .init(score: 95, statement: "I would plan around going here."),
        .init(score: 85, statement: "I am genuinely excited to return."),
        .init(score: 75, statement: "I would happily return."),
        .init(score: 65, statement: "I would go under the right circumstances."),
        .init(score: 50, statement: "I feel neutral about returning."),
        .init(score: 35, statement: "I would usually choose somewhere else."),
        .init(score: 15, statement: "I actively want to avoid returning.")
    ]
}
