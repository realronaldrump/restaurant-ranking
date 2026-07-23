import CoreData
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let restaurantLogBackup = UTType(
        exportedAs: "com.davis.bigbeautiful.backup",
        conformingTo: .json
    )
}

struct AppBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.restaurantLogBackup]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw AppBackupError.unreadable
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct AppBackupSummary: Equatable, Sendable {
    let circles: Int
    let locations: Int
    let visits: Int
    let photos: Int
}

enum AppBackupError: LocalizedError, Equatable {
    case unreadable
    case invalidFormat
    case unsupportedVersion(Int)
    case duplicateIdentifier(String)
    case missingReference(String)
    case noDestinationStore

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The backup file could not be read."
        case .invalidFormat:
            "This is not a valid Big Beautiful backup."
        case let .unsupportedVersion(version):
            "This backup uses format version \(version), which this version of Big Beautiful cannot restore. Update the app and try again."
        case let .duplicateIdentifier(kind):
            "The backup contains a duplicate \(kind) identifier and cannot be restored safely."
        case let .missingReference(detail):
            "The backup is incomplete (\(detail)) and cannot be restored safely."
        case .noDestinationStore:
            "The app could not find a local database for the restored log."
        }
    }
}

struct AppBackupArchive: Codable, Sendable {
    static let signature = "big-beautiful-restaurant-log"
    static let currentFormatVersion = 1

    var signature: String
    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String
    var preferences: Preferences
    var activeCircleID: UUID?
    var deviceSelections: [DeviceSelection]
    var circles: [CircleRecord]
    var people: [PersonRecord]
    var brands: [BrandRecord]
    var locations: [LocationRecord]
    var visits: [VisitRecord]
    var ratings: [RatingRecord]
    var dishes: [DishRecord]
    var dishEntries: [DishEntryRecord]
    var photos: [PhotoRecord]
    var comparisons: [ComparisonRecord]
    var wantEntries: [WantRecord]

    struct Preferences: Codable, Sendable {
        var hapticsEnabled: Bool
    }

    struct DeviceSelection: Codable, Sendable {
        var circleID: UUID
        var personID: UUID
    }

    struct CircleRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var createdAt: Date
    }

    struct PersonRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var isMe: Bool
        var isCircleMember: Bool
        var colorHex: String
        var createdAt: Date
        var circleID: UUID?
    }

    struct BrandRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var createdAt: Date
    }

    struct LocationRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var category: DiningCategory
        var address: String?
        var city: String?
        var phone: String?
        var urlString: String?
        var hoursText: String?
        var latitude: Double
        var longitude: Double
        var hasCoordinates: Bool
        var isClosed: Bool
        var sourceIdentifier: String?
        var cuisines: [String]
        var tags: [String]
        var createdAt: Date
        var updatedAt: Date
        var circleID: UUID?
        var brandID: UUID?
    }

    struct VisitRecord: Codable, Sendable {
        var id: UUID
        var date: Date
        var visitType: VisitType?
        var priceBand: Int16
        var occasion: Occasion?
        var memory: String?
        var latitude: Double
        var longitude: Double
        var hasCoordinates: Bool
        var createdAt: Date
        var isShared: Bool
        var createdByID: UUID
        var companionIDs: [UUID]
        var circleID: UUID?
        var locationID: UUID?
    }

    struct RatingRecord: Codable, Sendable {
        var id: UUID
        var personID: UUID
        var reaction: Reaction
        var service: Reaction?
        var atmosphere: Reaction?
        var value: Reaction?
        var hazyMemory: Bool
        var wouldOrderAgain: Bool
        var hasWouldOrderAgain: Bool
        var createdAt: Date
        var visitID: UUID?
    }

    struct DishRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var role: DishRole
        var createdAt: Date
        var isArchived: Bool
        var locationID: UUID?
    }

    struct DishEntryRecord: Codable, Sendable {
        var id: UUID
        var personID: UUID
        var reaction: Reaction
        var wouldOrderAgain: Bool
        var createdAt: Date
        var dishID: UUID?
        var visitID: UUID?
    }

    struct PhotoRecord: Codable, Sendable {
        var id: UUID
        var thumbnailData: Data?
        var fullData: Data?
        var createdAt: Date
        var captureDate: Date?
        var visitID: UUID?
    }

    struct ComparisonRecord: Codable, Sendable {
        var id: UUID
        var personID: UUID
        var locationAID: UUID
        var locationBID: UUID
        var outcome: ComparisonOutcome
        var date: Date
        var isAnchor: Bool
        var anchorValue: Double
        var locationAEvidenceFingerprint: String?
        var locationBEvidenceFingerprint: String?
        var circleID: UUID?
    }

    struct WantRecord: Codable, Sendable {
        var id: UUID
        var addedByID: UUID
        var addedAt: Date
        var circleID: UUID?
        var locationID: UUID?
    }

    var summary: AppBackupSummary {
        .init(circles: circles.count, locations: locations.count, visits: visits.count, photos: photos.count)
    }
}

enum AppBackupCodec {
    private struct ArchiveHeader: Decodable {
        let signature: String
        let formatVersion: Int
    }

    static func encode(_ archive: AppBackupArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> AppBackupArchive {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let header = try decoder.decode(ArchiveHeader.self, from: data)
            guard header.signature == AppBackupArchive.signature else { throw AppBackupError.invalidFormat }
            guard header.formatVersion == AppBackupArchive.currentFormatVersion else {
                throw AppBackupError.unsupportedVersion(header.formatVersion)
            }
            let archive = try decoder.decode(AppBackupArchive.self, from: data)
            try validate(archive)
            return archive
        } catch let error as AppBackupError {
            throw error
        } catch {
            throw AppBackupError.invalidFormat
        }
    }

    static func validate(_ archive: AppBackupArchive) throws {
        guard archive.signature == AppBackupArchive.signature else { throw AppBackupError.invalidFormat }
        guard archive.formatVersion == AppBackupArchive.currentFormatVersion else {
            throw AppBackupError.unsupportedVersion(archive.formatVersion)
        }

        let circleIDs = try uniqueIDs(archive.circles.map(\.id), kind: "circle")
        _ = try uniqueIDs(archive.people.map(\.id), kind: "person")
        let brandIDs = try uniqueIDs(archive.brands.map(\.id), kind: "brand")
        _ = try uniqueIDs(archive.locations.map(\.id), kind: "restaurant")
        _ = try uniqueIDs(archive.visits.map(\.id), kind: "visit")
        _ = try uniqueIDs(archive.ratings.map(\.id), kind: "rating")
        _ = try uniqueIDs(archive.dishes.map(\.id), kind: "dish")
        _ = try uniqueIDs(archive.dishEntries.map(\.id), kind: "dish entry")
        _ = try uniqueIDs(archive.photos.map(\.id), kind: "photo")
        _ = try uniqueIDs(archive.comparisons.map(\.id), kind: "comparison")
        _ = try uniqueIDs(archive.wantEntries.map(\.id), kind: "wish-list entry")
        _ = try uniqueIDs(archive.deviceSelections.map(\.circleID), kind: "device selection")

        let personCircleIDs = try Dictionary(uniqueKeysWithValues: archive.people.map { person in
            (person.id, try require(person.circleID, in: circleIDs, detail: "person’s circle is missing"))
        })
        let locationCircleIDs = try Dictionary(uniqueKeysWithValues: archive.locations.map { location in
            (location.id, try require(location.circleID, in: circleIDs, detail: "restaurant’s circle is missing"))
        })
        let locationIDs = Set(locationCircleIDs.keys)
        let visitCircleIDs = try Dictionary(uniqueKeysWithValues: archive.visits.map { visit in
            (visit.id, try require(visit.circleID, in: circleIDs, detail: "visit’s circle is missing"))
        })
        let visitLocationIDs = try Dictionary(uniqueKeysWithValues: archive.visits.map { visit in
            (visit.id, try require(visit.locationID, in: locationIDs, detail: "visit’s restaurant is missing"))
        })
        let visitIDs = Set(visitCircleIDs.keys)
        let dishLocationIDs = try Dictionary(uniqueKeysWithValues: archive.dishes.map { dish in
            (dish.id, try require(dish.locationID, in: locationIDs, detail: "dish’s restaurant is missing"))
        })
        let dishIDs = Set(dishLocationIDs.keys)

        if let activeCircleID = archive.activeCircleID, !circleIDs.contains(activeCircleID) {
            throw AppBackupError.missingReference("active circle is missing")
        }
        for selection in archive.deviceSelections {
            guard circleIDs.contains(selection.circleID),
                  personCircleIDs[selection.personID] == selection.circleID,
                  archive.people.first(where: { $0.id == selection.personID })?.isCircleMember == true else {
                throw AppBackupError.missingReference("device identity is missing")
            }
        }
        for location in archive.locations {
            if let brandID = location.brandID, !brandIDs.contains(brandID) {
                throw AppBackupError.missingReference("restaurant’s brand is missing")
            }
        }
        for visit in archive.visits {
            let circleID = visitCircleIDs[visit.id]!
            let locationID = visitLocationIDs[visit.id]!
            guard locationCircleIDs[locationID] == circleID else {
                throw AppBackupError.missingReference("visit and restaurant belong to different circles")
            }
            guard personCircleIDs[visit.createdByID] == circleID else {
                throw AppBackupError.missingReference("visit creator is missing from its circle")
            }
            guard visit.companionIDs.allSatisfy({ personCircleIDs[$0] == circleID }) else {
                throw AppBackupError.missingReference("visit companion is missing from its circle")
            }
            guard Set(visit.companionIDs).count == visit.companionIDs.count else {
                throw AppBackupError.missingReference("visit contains a duplicate companion")
            }
        }
        for rating in archive.ratings {
            let visitID = try require(rating.visitID, in: visitIDs, detail: "rating’s visit is missing")
            guard personCircleIDs[rating.personID] == visitCircleIDs[visitID] else {
                throw AppBackupError.missingReference("rating person is missing from the visit’s circle")
            }
        }
        for entry in archive.dishEntries {
            let dishID = try require(entry.dishID, in: dishIDs, detail: "dish entry’s dish is missing")
            let visitID = try require(entry.visitID, in: visitIDs, detail: "dish entry’s visit is missing")
            let visitCircleID = visitCircleIDs[visitID]!
            guard locationCircleIDs[dishLocationIDs[dishID]!] == visitCircleID else {
                throw AppBackupError.missingReference("dish entry and visit belong to different circles")
            }
            guard personCircleIDs[entry.personID] == visitCircleID else {
                throw AppBackupError.missingReference("dish entry person is missing from the visit’s circle")
            }
        }
        for photo in archive.photos {
            _ = try require(photo.visitID, in: visitIDs, detail: "photo’s visit is missing")
        }
        for comparison in archive.comparisons {
            let circleID = try require(comparison.circleID, in: circleIDs, detail: "comparison’s circle is missing")
            guard locationCircleIDs[comparison.locationAID] == circleID,
                  locationCircleIDs[comparison.locationBID] == circleID else {
                throw AppBackupError.missingReference("comparison’s restaurant is missing")
            }
            guard personCircleIDs[comparison.personID] == circleID else {
                throw AppBackupError.missingReference("comparison person is missing from its circle")
            }
            guard comparison.isAnchor == (comparison.locationAID == comparison.locationBID) else {
                throw AppBackupError.missingReference("comparison has inconsistent restaurant references")
            }
        }
        for want in archive.wantEntries {
            let circleID = try require(want.circleID, in: circleIDs, detail: "wish-list entry’s circle is missing")
            let locationID = try require(want.locationID, in: locationIDs, detail: "wish-list restaurant is missing")
            guard locationCircleIDs[locationID] == circleID else {
                throw AppBackupError.missingReference("wish-list restaurant belongs to a different circle")
            }
            guard personCircleIDs[want.addedByID] == circleID else {
                throw AppBackupError.missingReference("wish-list person is missing from its circle")
            }
        }
    }

    private static func uniqueIDs(_ ids: [UUID], kind: String) throws -> Set<UUID> {
        let result = Set(ids)
        guard result.count == ids.count else { throw AppBackupError.duplicateIdentifier(kind) }
        return result
    }

    @discardableResult
    private static func require(_ id: UUID?, in ids: Set<UUID>, detail: String) throws -> UUID {
        guard let id, ids.contains(id) else { throw AppBackupError.missingReference(detail) }
        return id
    }
}

enum AppBackupService {
    @MainActor
    static func makeArchive(from store: AppStore) async throws -> AppBackupArchive {
        try store.persistence.save()
        let context = store.persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        let exportedAt = Date.now
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let hapticsEnabled = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
        let activeCircleID = store.activeCircleID
        let deviceSelections: [AppBackupArchive.DeviceSelection] = store.circles.compactMap { circle in
            store.selectedPersonIDForBackup(circleID: circle.id).map {
                .init(circleID: circle.id, personID: $0)
            }
        }.sorted { $0.circleID.uuidString < $1.circleID.uuidString }

        let archive = try await context.perform {
            let circles: [CircleEntity] = try fetch(in: context)
            let people: [PersonEntity] = try fetch(in: context)
            let brands: [BrandEntity] = try fetch(in: context)
            let locations: [RestaurantLocation] = try fetch(in: context)
            let visits: [VisitEntity] = try fetch(in: context)
            let ratings: [RatingEntity] = try fetch(in: context)
            let dishes: [DishEntity] = try fetch(in: context)
            let dishEntries: [DishEntryEntity] = try fetch(in: context)
            let photos: [PhotoEntity] = try fetch(in: context)
            let comparisons: [ComparisonEntity] = try fetch(in: context)
            let wantEntries: [WantEntryEntity] = try fetch(in: context)

            let archive = AppBackupArchive(
                signature: AppBackupArchive.signature,
                formatVersion: AppBackupArchive.currentFormatVersion,
                exportedAt: exportedAt,
                appVersion: appVersion,
                preferences: .init(hapticsEnabled: hapticsEnabled),
                activeCircleID: activeCircleID,
                deviceSelections: deviceSelections,
                circles: circles.map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt) },
                people: people.map {
                    .init(id: $0.id, name: $0.name, isMe: $0.isMe, isCircleMember: $0.isCircleMember,
                          colorHex: $0.colorHex, createdAt: $0.createdAt, circleID: $0.circle?.id)
                },
                brands: brands.map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt) },
                locations: locations.map {
                    .init(id: $0.id, name: $0.name, category: $0.category, address: $0.address, city: $0.city,
                          phone: $0.phone, urlString: $0.urlString, hoursText: $0.hoursText,
                          latitude: $0.latitude, longitude: $0.longitude, hasCoordinates: $0.hasCoordinates,
                          isClosed: $0.isClosed, sourceIdentifier: $0.sourceIdentifier, cuisines: $0.cuisines,
                          tags: $0.tags, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                          circleID: $0.circle?.id, brandID: $0.brand?.id)
                },
                visits: visits.map {
                    .init(id: $0.id, date: $0.date, visitType: $0.visitType, priceBand: $0.priceBand,
                          occasion: $0.occasion, memory: $0.memory, latitude: $0.latitude, longitude: $0.longitude,
                          hasCoordinates: $0.hasCoordinates, createdAt: $0.createdAt, isShared: $0.isShared,
                          createdByID: $0.createdByID, companionIDs: $0.companionIDs,
                          circleID: $0.circle?.id, locationID: $0.location?.id)
                },
                ratings: ratings.map {
                    .init(id: $0.id, personID: $0.personID, reaction: $0.reaction, service: $0.service,
                          atmosphere: $0.atmosphere, value: $0.value, hazyMemory: $0.hazyMemory,
                          wouldOrderAgain: $0.wouldOrderAgain, hasWouldOrderAgain: $0.hasWouldOrderAgain,
                          createdAt: $0.createdAt, visitID: $0.visit?.id)
                },
                dishes: dishes.map {
                    .init(id: $0.id, name: $0.name, role: $0.role, createdAt: $0.createdAt,
                          isArchived: $0.isArchived, locationID: $0.location?.id)
                },
                dishEntries: dishEntries.map {
                    .init(id: $0.id, personID: $0.personID, reaction: $0.reaction,
                          wouldOrderAgain: $0.wouldOrderAgain, createdAt: $0.createdAt,
                          dishID: $0.dish?.id, visitID: $0.visit?.id)
                },
                photos: photos.map {
                    .init(id: $0.id, thumbnailData: $0.thumbnailData, fullData: $0.fullData,
                          createdAt: $0.createdAt, captureDate: $0.captureDate, visitID: $0.visit?.id)
                },
                comparisons: comparisons.map {
                    .init(id: $0.id, personID: $0.personID, locationAID: $0.locationAID,
                          locationBID: $0.locationBID, outcome: $0.outcome, date: $0.date,
                          isAnchor: $0.isAnchor, anchorValue: $0.anchorValue,
                          locationAEvidenceFingerprint: $0.locationAEvidenceFingerprint,
                          locationBEvidenceFingerprint: $0.locationBEvidenceFingerprint,
                          circleID: $0.circle?.id)
                },
                wantEntries: wantEntries.map {
                    .init(id: $0.id, addedByID: $0.addedByID, addedAt: $0.addedAt,
                          circleID: $0.circle?.id, locationID: $0.location?.id)
                }
            )
            try AppBackupCodec.validate(archive)
            return archive
        }
        return archive
    }

    @discardableResult
    @MainActor
    static func restore(_ archive: AppBackupArchive, into store: AppStore) async throws -> AppBackupSummary {
        try await Task.detached(priority: .userInitiated) {
            try AppBackupCodec.validate(archive)
        }.value
        let context = store.persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            guard let destinationStore = context.persistentStoreCoordinator?.persistentStores.first(where: {
                $0.url?.lastPathComponent.contains("-shared") != true
            }) else { throw AppBackupError.noDestinationStore }

            do {
            for entity in ManagedObjectModel.make().entities.compactMap(\.name) {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                for object in try context.fetch(request) { context.delete(object) }
            }

            var circles: [UUID: CircleEntity] = [:]
            for record in archive.circles {
                let object = CircleEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.name = record.name; object.createdAt = record.createdAt
                circles[record.id] = object
            }
            var brands: [UUID: BrandEntity] = [:]
            for record in archive.brands {
                let object = BrandEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.name = record.name; object.createdAt = record.createdAt
                brands[record.id] = object
            }
            for record in archive.people {
                let object = PersonEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.name = record.name; object.isMe = record.isMe
                object.isCircleMember = record.isCircleMember; object.colorHex = record.colorHex
                object.createdAt = record.createdAt; object.circle = record.circleID.flatMap { circles[$0] }
            }
            var locations: [UUID: RestaurantLocation] = [:]
            for record in archive.locations {
                let object = RestaurantLocation(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.name = record.name; object.category = record.category
                object.address = record.address; object.city = record.city; object.phone = record.phone
                object.urlString = record.urlString; object.hoursText = record.hoursText
                object.latitude = record.latitude; object.longitude = record.longitude
                object.hasCoordinates = record.hasCoordinates; object.isClosed = record.isClosed
                object.sourceIdentifier = record.sourceIdentifier; object.cuisines = record.cuisines; object.tags = record.tags
                object.createdAt = record.createdAt; object.updatedAt = record.updatedAt
                object.circle = record.circleID.flatMap { circles[$0] }; object.brand = record.brandID.flatMap { brands[$0] }
                locations[record.id] = object
            }
            var dishes: [UUID: DishEntity] = [:]
            for record in archive.dishes {
                let object = DishEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.name = record.name; object.role = record.role
                object.createdAt = record.createdAt; object.isArchived = record.isArchived
                object.location = record.locationID.flatMap { locations[$0] }
                dishes[record.id] = object
            }
            var visits: [UUID: VisitEntity] = [:]
            for record in archive.visits {
                let object = VisitEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.date = record.date; object.visitType = record.visitType
                object.priceBand = record.priceBand; object.occasion = record.occasion; object.memory = record.memory
                object.latitude = record.latitude; object.longitude = record.longitude; object.hasCoordinates = record.hasCoordinates
                object.createdAt = record.createdAt; object.isShared = record.isShared; object.createdByID = record.createdByID
                object.companionIDs = record.companionIDs; object.circle = record.circleID.flatMap { circles[$0] }
                object.location = record.locationID.flatMap { locations[$0] }
                visits[record.id] = object
            }
            for record in archive.ratings {
                let object = RatingEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.personID = record.personID; object.reaction = record.reaction
                object.service = record.service; object.atmosphere = record.atmosphere; object.value = record.value
                object.hazyMemory = record.hazyMemory; object.wouldOrderAgain = record.wouldOrderAgain
                object.hasWouldOrderAgain = record.hasWouldOrderAgain; object.createdAt = record.createdAt
                object.visit = record.visitID.flatMap { visits[$0] }
            }
            for record in archive.dishEntries {
                let object = DishEntryEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.personID = record.personID; object.reaction = record.reaction
                object.wouldOrderAgain = record.wouldOrderAgain; object.createdAt = record.createdAt
                object.dish = record.dishID.flatMap { dishes[$0] }; object.visit = record.visitID.flatMap { visits[$0] }
            }
            for record in archive.photos {
                let object = PhotoEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.thumbnailData = record.thumbnailData; object.fullData = record.fullData
                object.createdAt = record.createdAt; object.captureDate = record.captureDate
                object.visit = record.visitID.flatMap { visits[$0] }
            }
            for record in archive.comparisons {
                let object = ComparisonEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.personID = record.personID; object.locationAID = record.locationAID
                object.locationBID = record.locationBID; object.outcome = record.outcome; object.date = record.date
                object.isAnchor = record.isAnchor; object.anchorValue = record.anchorValue
                object.locationAEvidenceFingerprint = record.locationAEvidenceFingerprint ?? ""
                object.locationBEvidenceFingerprint = record.locationBEvidenceFingerprint ?? ""
                object.circle = record.circleID.flatMap { circles[$0] }
            }
            for record in archive.wantEntries {
                let object = WantEntryEntity(context: context); context.assign(object, to: destinationStore)
                object.id = record.id; object.addedByID = record.addedByID; object.addedAt = record.addedAt
                object.circle = record.circleID.flatMap { circles[$0] }; object.location = record.locationID.flatMap { locations[$0] }
            }

                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }

        UserDefaults.standard.set(archive.preferences.hapticsEnabled, forKey: "hapticsEnabled")
        store.completeBackupRestore(
            activeCircleID: archive.activeCircleID,
            selections: Dictionary(uniqueKeysWithValues: archive.deviceSelections.map { ($0.circleID, $0.personID) })
        )
        return archive.summary
    }

    private static func fetch<T: NSManagedObject>(in context: NSManagedObjectContext) throws -> [T] {
        let request = NSFetchRequest<T>(entityName: String(describing: T.self))
        return try context.fetch(request).sorted { lhs, rhs in
            let left = (lhs.value(forKey: "id") as? UUID)?.uuidString ?? ""
            let right = (rhs.value(forKey: "id") as? UUID)?.uuidString ?? ""
            return left < right
        }
    }
}
