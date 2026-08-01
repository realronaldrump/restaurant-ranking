import CoreData
import CryptoKit
import XCTest
@testable import RestaurantLog

@MainActor
final class LegacyStoreConsolidatorTests: XCTestCase {
    /// Environment-backed proof against the copied on-device 2.x store. The
    /// fixture's contents are intentionally git-ignored; CI skips this one test
    /// when no local device snapshot has been supplied.
    func testCopiedDeviceStorePreservesEveryRelationshipAndPhotoBlob() async throws {
        guard let fixtureURL = Bundle(for: LegacyStoreConsolidatorTests.self).resourceURL?
            .appendingPathComponent("LocalDeviceFixture", isDirectory: true),
            FileManager.default.fileExists(
                atPath: fixtureURL.appendingPathComponent("BigBeautiful-private.sqlite").path
            ) else {
            throw XCTSkip("No local device-store fixture is bundled on this machine.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-consolidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try copyContents(of: fixtureURL, into: directory)

        let sourceURL = directory.appendingPathComponent("BigBeautiful-private.sqlite")
        let destinationURL = directory.appendingPathComponent("Consolidated.sqlite")
        let fingerprintURL = try LegacyStoreConsolidator.makeRecoveryCopy(of: sourceURL)
        let expected = try fingerprintStore(at: fingerprintURL)
        XCTAssertGreaterThan(expected.relationships.filter { $0.targetID != nil }.count, 0)
        XCTAssertGreaterThan(expected.photos.count, 0)
        XCTAssertTrue(expected.photos.values.allSatisfy {
            $0.fullData.byteCount > 0 && $0.thumbnailData.byteCount > 0
        })

        let copied = try await LegacyStoreConsolidator.consolidate(
            from: sourceURL,
            into: destinationURL
        )

        XCTAssertEqual(copied, expected.objectCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try fingerprintStore(at: destinationURL), expected)
    }

    func testCopiedLegacyStorePreservesRelationshipsAndPhotoBlobs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-consolidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("BigBeautiful-shared.sqlite")
        let destinationURL = directory.appendingPathComponent("BigBeautiful-private.sqlite")
        let legacy = try makeContainer(at: legacyURL)
        let destination = try makeContainer(at: destinationURL)

        let circle = CircleEntity(context: legacy.viewContext)
        circle.id = UUID(); circle.name = "Legacy Circle"; circle.createdAt = .now
        let person = PersonEntity(context: legacy.viewContext)
        person.id = UUID(); person.name = "Legacy Owner"; person.isMe = true
        person.isCircleMember = true; person.colorHex = "6F1D2B"; person.createdAt = .now
        person.circle = circle
        let location = RestaurantLocation(context: legacy.viewContext)
        location.id = UUID(); location.name = "Blob Bistro"; location.category = .fullService
        location.createdAt = .now; location.updatedAt = .now; location.circle = circle
        let visit = VisitEntity(context: legacy.viewContext)
        visit.id = UUID(); visit.date = .now; visit.dateKnowledge = .known
        visit.priceBand = 2; visit.createdAt = .now; visit.createdByID = person.id
        visit.circle = circle; visit.location = location
        let photo = PhotoEntity(context: legacy.viewContext)
        photo.id = UUID(); photo.createdAt = .now; photo.personID = person.id; photo.visit = visit
        photo.fullData = Data(repeating: 0xAB, count: 512 * 1_024)
        photo.thumbnailData = Data(repeating: 0xCD, count: 32 * 1_024)
        try legacy.viewContext.save()

        try close(legacy)
        try close(destination)

        let copiedURL = try LegacyStoreConsolidator.makeRecoveryCopy(of: legacyURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))

        let copied = try await LegacyStoreConsolidator.merge(
            from: copiedURL,
            into: destinationURL
        )
        XCTAssertEqual(copied, 5)

        let reloaded = try makeContainer(at: destinationURL)
        defer { try? close(reloaded) }
        let restoredPhoto = try XCTUnwrap(reloaded.viewContext.fetch(
            NSFetchRequest<PhotoEntity>(entityName: "PhotoEntity")
        ).first)
        XCTAssertEqual(restoredPhoto.fullData, Data(repeating: 0xAB, count: 512 * 1_024))
        XCTAssertEqual(restoredPhoto.thumbnailData, Data(repeating: 0xCD, count: 32 * 1_024))
        XCTAssertEqual(restoredPhoto.visit?.location?.name, "Blob Bistro")
        XCTAssertEqual(restoredPhoto.visit?.circle?.name, "Legacy Circle")
        XCTAssertEqual(restoredPhoto.visit?.circle?.people?.count, 1)
    }

    func testFailedConsolidationLeavesTheOriginalStoreIntact() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-consolidation-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("BigBeautiful-shared.sqlite")
        let legacy = try makeContainer(at: legacyURL)
        let circle = CircleEntity(context: legacy.viewContext)
        circle.id = UUID(); circle.name = "Only Copy"; circle.createdAt = .now
        try legacy.viewContext.save()
        try close(legacy)

        let impossibleDestination = directory.appendingPathComponent("DestinationIsADirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: impossibleDestination, withIntermediateDirectories: true)

        do {
            _ = try await LegacyStoreConsolidator.consolidate(
                from: legacyURL,
                into: impossibleDestination
            )
            XCTFail("Expected a destination-store failure")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
            let reopened = try makeContainer(at: legacyURL)
            defer { try? close(reopened) }
            let circles = try reopened.viewContext.fetch(
                NSFetchRequest<CircleEntity>(entityName: "CircleEntity")
            )
            XCTAssertEqual(circles.map(\.name), ["Only Copy"])
        }
    }

    private func fingerprintStore(at url: URL) throws -> StoreFingerprint {
        let container = try makeContainer(at: url, readOnly: true)
        defer { try? close(container) }
        let context = container.viewContext

        return try context.performAndWait {
            var entityIDs: [String: [String]] = [:]
            var relationships: [RelationshipEdge] = []
            var photos: [String: PhotoFingerprint] = [:]

            for entity in ManagedObjectModel.make().entities.sorted(by: {
                ($0.name ?? "") < ($1.name ?? "")
            }) {
                guard let entityName = entity.name else { continue }
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.returnsObjectsAsFaults = false
                let objects = try context.fetch(request).sorted {
                    (($0.value(forKey: "id") as? UUID)?.uuidString ?? "")
                        < (($1.value(forKey: "id") as? UUID)?.uuidString ?? "")
                }

                entityIDs[entityName] = try objects.map { object in
                    let id = try XCTUnwrap(object.value(forKey: "id") as? UUID)
                    for (name, relationship) in object.entity.relationshipsByName
                        where !relationship.isToMany {
                        let related = object.value(forKey: name) as? NSManagedObject
                        relationships.append(RelationshipEdge(
                            entity: entityName,
                            sourceID: id.uuidString,
                            relationship: name,
                            targetEntity: related?.entity.name,
                            targetID: (related?.value(forKey: "id") as? UUID)?.uuidString
                        ))
                    }

                    if let photo = object as? PhotoEntity {
                        photos[id.uuidString] = PhotoFingerprint(
                            fullData: BlobFingerprint(data: photo.fullData),
                            thumbnailData: BlobFingerprint(data: photo.thumbnailData)
                        )
                    }
                    return id.uuidString
                }
            }

            relationships.sort { $0.sortKey < $1.sortKey }
            return StoreFingerprint(
                entityIDs: entityIDs,
                relationships: relationships,
                photos: photos
            )
        }
    }

    private func copyContents(of source: URL, into destination: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.copyItem(
                at: item,
                to: destination.appendingPathComponent(item.lastPathComponent)
            )
        }
    }

    private func makeContainer(at url: URL, readOnly: Bool = false) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "RestaurantLog", managedObjectModel: ManagedObjectModel.make())
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        description.setOption(readOnly as NSNumber, forKey: NSReadOnlyPersistentStoreOption)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container
    }

    private func close(_ container: NSPersistentContainer) throws {
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}

private struct StoreFingerprint: Equatable {
    let entityIDs: [String: [String]]
    let relationships: [RelationshipEdge]
    let photos: [String: PhotoFingerprint]

    var objectCount: Int { entityIDs.values.reduce(0) { $0 + $1.count } }
}

private struct RelationshipEdge: Equatable {
    let entity: String
    let sourceID: String
    let relationship: String
    let targetEntity: String?
    let targetID: String?

    var sortKey: String {
        [entity, sourceID, relationship, targetEntity ?? "", targetID ?? ""]
            .joined(separator: "\u{0}")
    }
}

private struct PhotoFingerprint: Equatable {
    let fullData: BlobFingerprint
    let thumbnailData: BlobFingerprint
}

private struct BlobFingerprint: Equatable {
    let byteCount: Int
    let sha256: String

    init(data: Data?) {
        let data = data ?? Data()
        byteCount = data.count
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
