import CoreData
import Foundation

enum ManagedObjectModel {
    private static let shared = build()

    static func make() -> NSManagedObjectModel {
        shared
    }

    private static func build() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let circle = entity("CircleEntity", CircleEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("name", .stringAttributeType), attribute("createdAt", .dateAttributeType)
        ])
        let person = entity("PersonEntity", PersonEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("name", .stringAttributeType),
            attribute("isMe", .booleanAttributeType, defaultValue: false), attribute("isCircleMember", .booleanAttributeType, defaultValue: true),
            attribute("colorHex", .stringAttributeType, defaultValue: "6F1D2B"),
            attribute("createdAt", .dateAttributeType)
        ])
        let brand = entity("BrandEntity", BrandEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("name", .stringAttributeType), attribute("createdAt", .dateAttributeType)
        ])
        let location = entity("RestaurantLocation", RestaurantLocation.self, [
            attribute("id", .UUIDAttributeType), attribute("name", .stringAttributeType), attribute("categoryRaw", .stringAttributeType),
            attribute("address", .stringAttributeType, optional: true), attribute("city", .stringAttributeType, optional: true),
            attribute("phone", .stringAttributeType, optional: true), attribute("urlString", .stringAttributeType, optional: true),
            attribute("hoursText", .stringAttributeType, optional: true), attribute("latitude", .doubleAttributeType, defaultValue: 0),
            attribute("longitude", .doubleAttributeType, defaultValue: 0), attribute("hasCoordinates", .booleanAttributeType, defaultValue: false),
            attribute("isClosed", .booleanAttributeType, defaultValue: false), attribute("sourceIdentifier", .stringAttributeType, optional: true),
            attribute("cuisineBlob", .binaryDataAttributeType, optional: true), attribute("tagBlob", .binaryDataAttributeType, optional: true),
            attribute("createdAt", .dateAttributeType), attribute("updatedAt", .dateAttributeType)
        ])
        let visit = entity("VisitEntity", VisitEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("date", .dateAttributeType),
            attribute("visitTypeRaw", .stringAttributeType, optional: true), attribute("priceBand", .integer16AttributeType, defaultValue: 0),
            attribute("occasionRaw", .stringAttributeType, optional: true), attribute("memory", .stringAttributeType, optional: true),
            attribute("latitude", .doubleAttributeType, defaultValue: 0), attribute("longitude", .doubleAttributeType, defaultValue: 0),
            attribute("hasCoordinates", .booleanAttributeType, defaultValue: false), attribute("createdAt", .dateAttributeType),
            attribute("isShared", .booleanAttributeType, defaultValue: false), attribute("createdByID", .UUIDAttributeType),
            attribute("companionIDsBlob", .binaryDataAttributeType, optional: true)
        ])
        let rating = entity("RatingEntity", RatingEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("personID", .UUIDAttributeType), attribute("reactionRaw", .stringAttributeType),
            attribute("serviceRaw", .stringAttributeType, optional: true), attribute("atmosphereRaw", .stringAttributeType, optional: true),
            attribute("valueRaw", .stringAttributeType, optional: true), attribute("hazyMemory", .booleanAttributeType, defaultValue: false),
            attribute("wouldOrderAgain", .booleanAttributeType, defaultValue: false), attribute("hasWouldOrderAgain", .booleanAttributeType, defaultValue: false),
            attribute("createdAt", .dateAttributeType)
        ])
        let dish = entity("DishEntity", DishEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("name", .stringAttributeType), attribute("roleRaw", .stringAttributeType),
            attribute("createdAt", .dateAttributeType), attribute("isArchived", .booleanAttributeType, defaultValue: false)
        ])
        let dishEntry = entity("DishEntryEntity", DishEntryEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("personID", .UUIDAttributeType), attribute("reactionRaw", .stringAttributeType),
            attribute("wouldOrderAgain", .booleanAttributeType, defaultValue: false), attribute("createdAt", .dateAttributeType)
        ])
        let photo = entity("PhotoEntity", PhotoEntity.self, [
            attribute("id", .UUIDAttributeType), binaryAttribute("thumbnailData", optional: true, external: true),
            binaryAttribute("fullData", optional: true, external: true), attribute("createdAt", .dateAttributeType)
        ])
        let comparison = entity("ComparisonEntity", ComparisonEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("personID", .UUIDAttributeType), attribute("locationAID", .UUIDAttributeType),
            attribute("locationBID", .UUIDAttributeType), attribute("outcomeRaw", .stringAttributeType), attribute("date", .dateAttributeType),
            attribute("isAnchor", .booleanAttributeType, defaultValue: false), attribute("anchorValue", .doubleAttributeType, defaultValue: 0)
        ])
        let want = entity("WantEntryEntity", WantEntryEntity.self, [
            attribute("id", .UUIDAttributeType), attribute("addedByID", .UUIDAttributeType), attribute("addedAt", .dateAttributeType)
        ])

        pair(circle, "people", person, "circle", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(circle, "locations", location, "circle", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(circle, "visits", visit, "circle", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(circle, "comparisons", comparison, "circle", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(circle, "wantEntries", want, "circle", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(brand, "locations", location, "brand", toManyA: true, deleteA: .nullifyDeleteRule)
        pair(location, "visits", visit, "location", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(location, "dishes", dish, "location", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(location, "wantEntries", want, "location", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(visit, "ratings", rating, "visit", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(visit, "dishEntries", dishEntry, "visit", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(visit, "photos", photo, "visit", toManyA: true, deleteA: .cascadeDeleteRule)
        pair(dish, "entries", dishEntry, "dish", toManyA: true, deleteA: .cascadeDeleteRule)

        model.entities = [circle, person, brand, location, visit, rating, dish, dishEntry, photo, comparison, want]
        return model
    }

    private static func entity(_ name: String, _ type: NSManagedObject.Type, _ properties: [NSPropertyDescription]) -> NSEntityDescription {
        let result = NSEntityDescription()
        result.name = name
        result.managedObjectClassName = NSStringFromClass(type)
        result.properties = properties
        return result
    }

    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
        let result = NSAttributeDescription()
        result.name = name
        result.attributeType = type
        result.isOptional = optional
        result.defaultValue = defaultValue ?? (optional ? nil : cloudKitDefaultValue(for: type))
        return result
    }

    /// CloudKit requires every required attribute to declare a model-level default.
    /// Insert paths still assign their real values explicitly; these sentinels make
    /// the schema valid and keep partially recovered records readable.
    private static func cloudKitDefaultValue(for type: NSAttributeType) -> Any? {
        switch type {
        case .stringAttributeType: ""
        case .UUIDAttributeType: UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        case .dateAttributeType: Date(timeIntervalSince1970: 0)
        case .booleanAttributeType: false
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: 0
        case .decimalAttributeType, .doubleAttributeType, .floatAttributeType: 0
        case .binaryDataAttributeType: Data()
        default: nil
        }
    }

    private static func binaryAttribute(_ name: String, optional: Bool, external: Bool) -> NSAttributeDescription {
        let result = attribute(name, .binaryDataAttributeType, optional: optional)
        result.allowsExternalBinaryDataStorage = external
        return result
    }

    private static func pair(
        _ a: NSEntityDescription, _ aName: String,
        _ b: NSEntityDescription, _ bName: String,
        toManyA: Bool, deleteA: NSDeleteRule
    ) {
        let aRelation = NSRelationshipDescription()
        aRelation.name = aName
        aRelation.destinationEntity = b
        aRelation.minCount = 0
        aRelation.maxCount = toManyA ? 0 : 1
        aRelation.isOptional = true
        aRelation.deleteRule = deleteA

        let bRelation = NSRelationshipDescription()
        bRelation.name = bName
        bRelation.destinationEntity = a
        bRelation.minCount = 0
        bRelation.maxCount = 1
        bRelation.isOptional = true
        bRelation.deleteRule = .nullifyDeleteRule

        aRelation.inverseRelationship = bRelation
        bRelation.inverseRelationship = aRelation
        a.properties.append(aRelation)
        b.properties.append(bRelation)
    }
}
