import CoreData
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
final class PersistenceController {
    static let shared: PersistenceController = {
        let arguments = ProcessInfo.processInfo.arguments
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return PersistenceController(
            inMemory: isRunningUnitTests || arguments.contains("-resetForUITests"),
            loadImmediately: false
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

    init(inMemory: Bool = false, loadImmediately: Bool = true) {
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
            if loadImmediately { prepareSynchronously() }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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

    private func prepareSynchronously() {
        loadError = loadStoresSynchronously()
        isReady = !container.persistentStoreCoordinator.persistentStores.isEmpty
        if isReady { adoptLegacySharedStoreIfPresent() }
    }

    @MainActor
    private func prepareAsynchronously() async {
        loadError = await loadStoresAsynchronously()
        isReady = !container.persistentStoreCoordinator.persistentStores.isEmpty
        if isReady { adoptLegacySharedStoreIfPresent() }
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

    // MARK: - Legacy shared store

    /// Folds anything that was living in the old CloudKit `.shared` store into
    /// the main store, once.
    ///
    /// Records that arrived through an accepted `CKShare` were written to a
    /// second local store. Dropping CloudKit without this step would leave that
    /// history on disk but invisible. Everything is merged by UUID, so a record
    /// present in both stores keeps a single identity, and the old file is moved
    /// aside rather than deleted.
    private func adoptLegacySharedStoreIfPresent() {
        let legacyURL = Self.storeDirectory.appendingPathComponent(Self.legacySharedStoreFileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard let destination = container.persistentStoreCoordinator.persistentStores.first else { return }

        let coordinator = container.persistentStoreCoordinator
        var legacyStore: NSPersistentStore?
        do {
            legacyStore = try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: legacyURL,
                options: [
                    NSReadOnlyPersistentStoreOption: true as NSNumber,
                    NSMigratePersistentStoresAutomaticallyOption: true as NSNumber,
                    NSInferMappingModelAutomaticallyOption: true as NSNumber
                ]
            )
        } catch {
            logger.error("Legacy shared store could not be opened: \(error.localizedDescription, privacy: .public)")
            notifyFailure("Records from the old iCloud shared log could not be opened. The file was left untouched at \(legacyURL.lastPathComponent).")
            return
        }
        guard let legacyStore else { return }

        do {
            legacyRecordsAdopted = try LegacyStoreConsolidator.merge(
                from: legacyStore,
                into: destination,
                container: container
            )
            try coordinator.remove(legacyStore)
            try LegacyStoreConsolidator.archiveFiles(at: legacyURL)
            logger.notice("Adopted \(self.legacyRecordsAdopted, privacy: .public) record(s) from the old shared store.")
        } catch {
            try? coordinator.remove(legacyStore)
            logger.error("Legacy shared store merge failed: \(error.localizedDescription, privacy: .public)")
            notifyFailure("Records from the old iCloud shared log could not be merged automatically. Nothing was deleted; export a backup from the previous version if anything is missing.")
        }
    }
}

/// Generic, model-driven copy between two stores of the same model.
///
/// Working from `NSEntityDescription` rather than fourteen hand-written cases
/// means a future entity is carried across without anyone remembering to update
/// this file.
enum LegacyStoreConsolidator {
    static func merge(
        from source: NSPersistentStore,
        into destination: NSPersistentStore,
        container: NSPersistentContainer
    ) throws -> Int {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.transactionAuthor = "legacy-adoption"

        var copied = 0
        var thrown: Error?

        context.performAndWait {
            do {
                let entities = container.managedObjectModel.entities.compactMap(\.name)
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
                            for name in object.entity.attributesByName.keys {
                                target.setValue(object.value(forKey: name), forKey: name)
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
                            guard
                                let related = object.value(forKey: name) as? NSManagedObject,
                                let relatedName = related.entity.name,
                                let relatedID = related.value(forKey: "id") as? UUID
                            else { continue }
                            let resolved = destinationsByEntity[relatedName]?[relatedID]
                                ?? (try? existing(relatedName, id: relatedID, in: destination, context: context))
                            if let resolved { target.setValue(resolved, forKey: name) }
                        }
                    }
                }

                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
                thrown = error
            }
        }

        if let thrown { throw thrown }
        return copied
    }

    /// Moves the retired store beside the live one instead of deleting it, so a
    /// merge that went wrong is still recoverable from the device.
    static func archiveFiles(at url: URL) throws {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent().appendingPathComponent("RetiredCloudKitStore", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = url.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(base + suffix)
            guard manager.fileExists(atPath: candidate.path) else { continue }
            let target = folder.appendingPathComponent(base + suffix)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.moveItem(at: candidate, to: target)
        }
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
