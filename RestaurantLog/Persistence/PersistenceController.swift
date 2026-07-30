@preconcurrency import CoreData
import Foundation
import OSLog

extension Notification.Name {
    static let persistenceDidFail = Notification.Name("RestaurantLog.persistenceDidFail")
}

enum PersistenceNotificationKey {
    static let message = "message"
}

/// Local storage.
///
/// The store is an ordinary `NSPersistentContainer`. Sharing between members no
/// longer runs through Core Data at all — it is a separate, inspectable delta
/// sync in `RestaurantLog/Sync`. That split is the point: the database on this
/// iPhone is the source of truth and is always writable, and network trouble
/// can delay a sync but can never prevent a meal from being logged.
@MainActor
final class PersistenceController {
    static let shared: PersistenceController = {
        let arguments = ProcessInfo.processInfo.arguments
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return PersistenceController(
            inMemory: isRunningUnitTests || arguments.contains("-resetForUITests")
        )
    }()

    static let storeFileName = "BigBeautiful-private.sqlite"
    /// The store that used to mirror the CloudKit `.shared` database. It is
    /// consolidated into the main store once, then set aside.
    static let legacySharedStoreFileName = "BigBeautiful-shared.sqlite"

    let container: NSPersistentContainer
    private(set) var loadError: Error?
    private(set) var isReady = false
    private(set) var legacyRecordsAdopted = 0

    private var preparationTask: Task<Void, Never>?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.davis.bigbeautifulranking",
        category: "Persistence"
    )

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "RestaurantLog", managedObjectModel: ManagedObjectModel.make())

        if inMemory {
            let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
            loadError = loadStoresSynchronously()
            isReady = loadError == nil
        } else {
            configureDescriptions()
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.transactionAuthor = "app"
        container.viewContext.undoManager = UndoManager()
    }

    /// Opens the store without blocking SwiftUI's first frame.
    @MainActor
    func prepare() async {
        if isReady { return }
        if let preparationTask {
            await preparationTask.value
            return
        }
        let task = Task { @MainActor in
            await prepareAsynchronously()
        }
        preparationTask = task
        await task.value
        preparationTask = nil
    }

    // MARK: - Store configuration

    static var storeDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    private func configureDescriptions() {
        container.persistentStoreDescriptions = [
            Self.description(url: Self.storeDirectory.appendingPathComponent(Self.storeFileName))
        ]
    }

    private static func description(url: URL) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        // History tracking stays on. It is no longer feeding a CloudKit mirror,
        // but it is what lets the view context merge background sync writes
        // cleanly and it costs almost nothing at this size.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        return description
    }

    @MainActor
    private func prepareAsynchronously() async {
        loadError = await loadStoresAsynchronously()
        isReady = !container.persistentStoreCoordinator.persistentStores.isEmpty
        if isReady { await importPreviousVersionSharedStoreIfPresent() }
    }

    private func loadStoresSynchronously() -> Error? {
        let descriptions = container.persistentStoreDescriptions
        descriptions.forEach { $0.shouldAddStoreAsynchronously = false }
        let state = PersistentStoreLoadState(expectedCompletions: descriptions.count)
        container.loadPersistentStores { _, error in
            _ = state.record(error)
        }
        return state.result
    }

    private func loadStoresAsynchronously() async -> Error? {
        let descriptions = container.persistentStoreDescriptions
        descriptions.forEach { $0.shouldAddStoreAsynchronously = true }
        let state = PersistentStoreLoadState(expectedCompletions: descriptions.count)
        return await withCheckedContinuation { continuation in
            container.loadPersistentStores { _, error in
                let update = state.record(error)
                if update.completed { continuation.resume(returning: update.error) }
            }
        }
    }

    func save() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        try context.save()
    }

    private func notifyFailure(_ message: String) {
        NotificationCenter.default.post(
            name: .persistenceDidFail,
            object: self,
            userInfo: [PersistenceNotificationKey.message: message]
        )
    }

    // MARK: - One-time previous-version data import

    /// Folds anything that was living in the old CloudKit `.shared` store into
    /// the main store, once.
    ///
    /// Records that arrived through an accepted `CKShare` were written to a
    /// second local store. Dropping CloudKit without this step would leave that
    /// history on disk but invisible. Everything is merged by UUID, so a record
    /// present in both stores keeps a single identity, and the old file is moved
    /// aside rather than deleted.
    private func importPreviousVersionSharedStoreIfPresent() async {
        let legacyURL = Self.storeDirectory.appendingPathComponent(Self.legacySharedStoreFileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        let destinationURL = Self.storeDirectory.appendingPathComponent(Self.storeFileName)

        do {
            legacyRecordsAdopted = try await LegacyStoreConsolidator.consolidate(
                from: legacyURL,
                into: destinationURL
            )
            // The import uses an independent private-queue stack. No app data
            // has been fetched yet, but resetting makes the visibility boundary
            // explicit before AppStore performs its first fetch.
            container.viewContext.reset()
            logger.notice("Adopted \(self.legacyRecordsAdopted, privacy: .public) record(s) from the old shared store.")
        } catch {
            logger.error("Legacy shared store merge failed: \(error.localizedDescription, privacy: .public)")
            notifyFailure("Records from the previous shared log could not be imported automatically. The original store and a recovery copy were left intact.")
        }
    }
}

/// Generic, model-driven copy between two stores of the same model.
///
/// Working from `NSEntityDescription` rather than fourteen hand-written cases
/// means a future entity is carried across without anyone remembering to update
/// this file.
enum LegacyStoreConsolidator {
    enum ConsolidationError: LocalizedError {
        case missingRelationship(entity: String, id: UUID, relationship: String)

        var errorDescription: String? {
            switch self {
            case let .missingRelationship(entity, id, relationship):
                "Could not resolve \(entity) \(id) relationship \(relationship)."
            }
        }
    }

    /// Creates a transactionally consistent Core Data copy, including WAL and
    /// externally stored photo blobs, in a unique retirement directory. The
    /// source is never modified by this operation.
    static func makeRecoveryCopy(of sourceURL: URL) throws -> URL {
        let manager = FileManager.default
        let folder = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("RetiredCloudKitStore", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destinationURL = folder.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: ManagedObjectModel.make())
            try coordinator.replacePersistentStore(
                at: destinationURL,
                destinationOptions: nil,
                withPersistentStoreFrom: sourceURL,
                sourceOptions: storeOptions(readOnly: true, historyTracking: false),
                ofType: NSSQLiteStoreType
            )
            return destinationURL
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    /// Copies, verifies, and merges on a utility task. The old store is retired
    /// only after the destination save commits successfully.
    static func consolidate(from sourceURL: URL, into destinationURL: URL) async throws -> Int {
        try await Task.detached(priority: .utility) {
            let recoveryURL = try makeRecoveryCopy(of: sourceURL)
            let copied = try mergeSynchronously(from: recoveryURL, into: destinationURL)
            try destroyStore(at: sourceURL)
            return copied
        }.value
    }

    static func merge(from sourceURL: URL, into destinationURL: URL) async throws -> Int {
        try await Task.detached(priority: .utility) {
            try mergeSynchronously(from: sourceURL, into: destinationURL)
        }.value
    }

    private static func mergeSynchronously(from sourceURL: URL, into destinationURL: URL) throws -> Int {
        let model = ManagedObjectModel.make()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let destination = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: destinationURL,
            options: storeOptions(readOnly: false, historyTracking: true)
        )
        let source = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: sourceURL,
            options: storeOptions(readOnly: true, historyTracking: false)
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        context.transactionAuthor = "previous-version-import"

        // Close both stores deterministically before the caller retires the
        // original. External binary attributes may otherwise still have lazy
        // clone work outstanding when the source files move, producing missing
        // `.interim` references even though the context save returned.
        defer {
            context.performAndWait { context.reset() }
            try? coordinator.remove(source)
            try? coordinator.remove(destination)
        }

        return try context.performAndWait {
            var copied = 0
            do {
                let entities = model.entities.compactMap(\.name)
                // Pass one: attributes only, so every object exists before any
                // relationship is pointed at it.
                var destinationsByEntity: [String: [UUID: NSManagedObject]] = [:]

                for entityName in entities {
                    let sources = try fetch(entityName, from: source, in: context)
                    guard !sources.isEmpty else { continue }
                    var mapped: [UUID: NSManagedObject] = [:]

                    for object in sources {
                        try autoreleasepool {
                            guard let id = object.value(forKey: "id") as? UUID else { return }
                            let target = try findOrCreate(
                                entityName,
                                id: id,
                                in: destination,
                                context: context
                            )
                            for (name, attribute) in object.entity.attributesByName {
                                target.setValue(
                                    ownedAttributeValue(
                                        object.value(forKey: name),
                                        attribute: attribute
                                    ),
                                    forKey: name
                                )
                            }
                            mapped[id] = target
                            copied += 1
                        }
                    }
                    destinationsByEntity[entityName] = mapped
                }

                // Pass two: to-one relationships. To-many sides are inverses and
                // follow automatically.
                for entityName in entities {
                    let sources = try fetch(entityName, from: source, in: context)
                    guard !sources.isEmpty else { continue }

                    for object in sources {
                        guard let id = object.value(forKey: "id") as? UUID,
                              let target = destinationsByEntity[entityName]?[id] else { continue }

                        for (name, relationship) in object.entity.relationshipsByName where !relationship.isToMany {
                            guard let related = object.value(forKey: name) as? NSManagedObject else {
                                target.setValue(nil, forKey: name)
                                continue
                            }
                            guard let relatedName = related.entity.name,
                                  let relatedID = related.value(forKey: "id") as? UUID else {
                                throw ConsolidationError.missingRelationship(
                                    entity: entityName,
                                    id: id,
                                    relationship: name
                                )
                            }
                            let resolved = destinationsByEntity[relatedName]?[relatedID]
                                ?? (try? existing(relatedName, id: relatedID, in: destination, context: context))
                            guard let resolved else {
                                throw ConsolidationError.missingRelationship(
                                    entity: entityName,
                                    id: id,
                                    relationship: name
                                )
                            }
                            target.setValue(resolved, forKey: name)
                        }
                    }
                }

                if context.hasChanges { try context.save() }
                return copied
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private static func destroyStore(at url: URL) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: ManagedObjectModel.make())
        try coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
        // `destroyPersistentStore` can leave the main SQLite marker behind even
        // after removing its contents. Its presence is our one-time import
        // trigger, so remove that harmless remnant explicitly. The consistent
        // recovery store already lives under RetiredCloudKitStore.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Core Data may vend externally stored binary attributes as file-backed
    /// `NSData` instances. Assigning one directly to another store can preserve
    /// a reference to a transient clone file instead of preserving the bytes.
    /// Materialize an independently owned buffer before the source stack goes
    /// away. Non-binary attributes remain model-driven and pass through.
    private static func ownedAttributeValue(
        _ value: Any?,
        attribute: NSAttributeDescription
    ) -> Any? {
        guard attribute.attributeType == .binaryDataAttributeType,
              let data = value as? Data else { return value }
        // `Data(UnsafeRawBufferPointer)` may retain Foundation's file-backed
        // NSData storage. Round-tripping through bytes forces ownership so the
        // destination cannot retain a reference to Core Data's `.interim` clone.
        return Data([UInt8](data))
    }

    private static func storeOptions(readOnly: Bool, historyTracking: Bool) -> [AnyHashable: Any] {
        var options: [AnyHashable: Any] = [
            NSReadOnlyPersistentStoreOption: readOnly as NSNumber,
            NSMigratePersistentStoresAutomaticallyOption: true as NSNumber,
            NSInferMappingModelAutomaticallyOption: true as NSNumber
        ]
        if historyTracking {
            options[NSPersistentHistoryTrackingKey] = true as NSNumber
            options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] = true as NSNumber
        }
        return options
    }

    private static func fetch(
        _ entityName: String,
        from store: NSPersistentStore,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.affectedStores = [store]
        request.returnsObjectsAsFaults = false
        return try context.fetch(request)
    }

    private static func existing(
        _ entityName: String,
        id: UUID,
        in store: NSPersistentStore,
        context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.affectedStores = [store]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func findOrCreate(
        _ entityName: String,
        id: UUID,
        in store: NSPersistentStore,
        context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        if let found = try existing(entityName, id: id, in: store, context: context) { return found }
        let created = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
        context.assign(created, to: store)
        created.setValue(id, forKey: "id")
        return created
    }
}

private final class PersistentStoreLoadState {
    private let lock = NSLock()
    private var remainingCompletions: Int
    private var firstError: Error?

    init(expectedCompletions: Int) {
        remainingCompletions = expectedCompletions
    }

    func record(_ error: Error?) -> (completed: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if firstError == nil { firstError = error }
        remainingCompletions -= 1
        return (remainingCompletions == 0, firstError)
    }

    var result: Error? {
        lock.lock()
        defer { lock.unlock() }
        return firstError
    }
}
