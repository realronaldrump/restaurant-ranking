import CoreData
import Foundation

@objc(CircleEntity)
final class CircleEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var createdAt: Date
    @NSManaged var people: NSSet?
    @NSManaged var locations: NSSet?
    @NSManaged var visits: NSSet?
    @NSManaged var comparisons: NSSet?
    @NSManaged var wantEntries: NSSet?
}

@objc(PersonEntity)
final class PersonEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var isMe: Bool
    @NSManaged var isCircleMember: Bool
    @NSManaged var colorHex: String
    @NSManaged var createdAt: Date
    @NSManaged var circle: CircleEntity?
}

@objc(BrandEntity)
final class BrandEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var createdAt: Date
    @NSManaged var locations: NSSet?
}

@objc(RestaurantLocation)
final class RestaurantLocation: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var categoryRaw: String
    @NSManaged var address: String?
    @NSManaged var city: String?
    @NSManaged var phone: String?
    @NSManaged var urlString: String?
    @NSManaged var hoursText: String?
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var hasCoordinates: Bool
    @NSManaged var isClosed: Bool
    @NSManaged var sourceIdentifier: String?
    @NSManaged var cuisineBlob: Data?
    @NSManaged var tagBlob: Data?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var circle: CircleEntity?
    @NSManaged var brand: BrandEntity?
    @NSManaged var visits: NSSet?
    @NSManaged var dishes: NSSet?
    @NSManaged var wantEntries: NSSet?

    var category: DiningCategory {
        get { DiningCategory(rawValue: categoryRaw) ?? .fullService }
        set { categoryRaw = newValue.rawValue }
    }
    var cuisines: [String] {
        get { Self.decodeStrings(cuisineBlob) }
        set { cuisineBlob = try? JSONEncoder().encode(newValue.uniqued().sorted()) }
    }
    var tags: [String] {
        get { Self.decodeStrings(tagBlob) }
        set { tagBlob = try? JSONEncoder().encode(newValue.uniqued().sorted()) }
    }
    var visitArray: [VisitEntity] {
        ((visits?.allObjects as? [VisitEntity]) ?? []).sorted { $0.date > $1.date }
    }
    var dishArray: [DishEntity] {
        ((dishes?.allObjects as? [DishEntity]) ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func hasVisit(inPriceBand priceBand: Int) -> Bool {
        (visits?.allObjects as? [VisitEntity])?.contains { Int($0.priceBand) == priceBand } ?? false
    }
    var coordinate: (latitude: Double, longitude: Double)? {
        hasCoordinates ? (latitude, longitude) : nil
    }
    private static func decodeStrings(_ data: Data?) -> [String] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

@objc(VisitEntity)
final class VisitEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var date: Date
    @NSManaged var visitTypeRaw: String?
    @NSManaged var priceBand: Int16
    @NSManaged var occasionRaw: String?
    @NSManaged var memory: String?
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var hasCoordinates: Bool
    @NSManaged var createdAt: Date
    @NSManaged var isShared: Bool
    @NSManaged var createdByID: UUID
    @NSManaged var companionIDsBlob: Data?
    @NSManaged var circle: CircleEntity?
    @NSManaged var location: RestaurantLocation?
    @NSManaged var ratings: NSSet?
    @NSManaged var dishEntries: NSSet?
    @NSManaged var photos: NSSet?

    var visitType: VisitType? {
        get { visitTypeRaw.flatMap(VisitType.init(rawValue:)) }
        set { visitTypeRaw = newValue?.rawValue }
    }
    var occasion: Occasion? {
        get { occasionRaw.flatMap(Occasion.init(rawValue:)) }
        set { occasionRaw = newValue?.rawValue }
    }
    var companionIDs: [UUID] {
        get {
            guard let data = companionIDsBlob else { return [] }
            return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
        }
        set { companionIDsBlob = try? JSONEncoder().encode(newValue.uniqued()) }
    }
    var ratingArray: [RatingEntity] { (ratings?.allObjects as? [RatingEntity]) ?? [] }
    var dishEntryArray: [DishEntryEntity] { (dishEntries?.allObjects as? [DishEntryEntity]) ?? [] }
    var photoArray: [PhotoEntity] {
        ((photos?.allObjects as? [PhotoEntity]) ?? []).sorted { $0.createdAt < $1.createdAt }
    }
    func rating(for personID: UUID) -> RatingEntity? { ratingArray.first { $0.personID == personID } }
}

@objc(RatingEntity)
final class RatingEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var personID: UUID
    @NSManaged var reactionRaw: String
    @NSManaged var serviceRaw: String?
    @NSManaged var atmosphereRaw: String?
    @NSManaged var valueRaw: String?
    @NSManaged var hazyMemory: Bool
    @NSManaged var wouldOrderAgain: Bool
    @NSManaged var hasWouldOrderAgain: Bool
    @NSManaged var createdAt: Date
    @NSManaged var visit: VisitEntity?

    var reaction: Reaction {
        get { Reaction(rawValue: reactionRaw) ?? .fine }
        set { reactionRaw = newValue.rawValue }
    }
    var service: Reaction? { get { serviceRaw.flatMap(Reaction.init(rawValue:)) } set { serviceRaw = newValue?.rawValue } }
    var atmosphere: Reaction? { get { atmosphereRaw.flatMap(Reaction.init(rawValue:)) } set { atmosphereRaw = newValue?.rawValue } }
    var value: Reaction? { get { valueRaw.flatMap(Reaction.init(rawValue:)) } set { valueRaw = newValue?.rawValue } }
}

@objc(DishEntity)
final class DishEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var roleRaw: String
    @NSManaged var createdAt: Date
    @NSManaged var isArchived: Bool
    @NSManaged var location: RestaurantLocation?
    @NSManaged var entries: NSSet?
    var role: DishRole { get { DishRole(rawValue: roleRaw) ?? .entree } set { roleRaw = newValue.rawValue } }
    var entryArray: [DishEntryEntity] { (entries?.allObjects as? [DishEntryEntity]) ?? [] }
}

@objc(DishEntryEntity)
final class DishEntryEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var personID: UUID
    @NSManaged var reactionRaw: String
    @NSManaged var wouldOrderAgain: Bool
    @NSManaged var createdAt: Date
    @NSManaged var dish: DishEntity?
    @NSManaged var visit: VisitEntity?
    var reaction: Reaction { get { Reaction(rawValue: reactionRaw) ?? .fine } set { reactionRaw = newValue.rawValue } }
}

@objc(PhotoEntity)
final class PhotoEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var thumbnailData: Data?
    @NSManaged var fullData: Data?
    @NSManaged var createdAt: Date
    @NSManaged var visit: VisitEntity?
}

@objc(ComparisonEntity)
final class ComparisonEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var personID: UUID
    @NSManaged var locationAID: UUID
    @NSManaged var locationBID: UUID
    @NSManaged var outcomeRaw: String
    @NSManaged var date: Date
    @NSManaged var isAnchor: Bool
    @NSManaged var anchorValue: Double
    @NSManaged var circle: CircleEntity?
    var outcome: ComparisonOutcome { get { ComparisonOutcome(rawValue: outcomeRaw) ?? .skipped } set { outcomeRaw = newValue.rawValue } }
}

@objc(WantEntryEntity)
final class WantEntryEntity: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var addedByID: UUID
    @NSManaged var addedAt: Date
    @NSManaged var circle: CircleEntity?
    @NSManaged var location: RestaurantLocation?
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
