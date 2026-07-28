import CloudKit
import CoreData
import UIKit

extension Notification.Name {
    static let cloudShareWasAccepted = Notification.Name("RestaurantLog.cloudShareWasAccepted")
    static let persistenceDidFail = Notification.Name("RestaurantLog.persistenceDidFail")
}

enum PersistenceNotificationKey {
    static let message = "message"
}

final class PersistenceController {
    static let shared: PersistenceController = {
        let arguments = ProcessInfo.processInfo.arguments
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return PersistenceController(
            inMemory: isRunningUnitTests || arguments.contains("-resetForUITests"),
            cloudEnabled: !isRunningUnitTests && !arguments.contains("-disableCloudKit") && !arguments.contains("-resetForUITests"),
            loadImmediately: false
        )
    }()
    static let cloudContainerIdentifier = "iCloud.com.davis.bigbeautifulranking"

    let container: NSPersistentCloudKitContainer
    private(set) var loadError: Error?
    private(set) var isCloudSyncActive = false
    private(set) var isReady = false

    private let prefersCloudSync: Bool
    private var preparationTask: Task<Void, Never>?

    init(inMemory: Bool = false, cloudEnabled: Bool = true, loadImmediately: Bool = true) {
        prefersCloudSync = cloudEnabled
        container = NSPersistentCloudKitContainer(name: "RestaurantLog", managedObjectModel: ManagedObjectModel.make())

        if inMemory {
            let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
            loadError = loadStoresSynchronously()
            isReady = loadError == nil
        } else {
            configureDescriptions(cloudEnabled: cloudEnabled)
            if loadImmediately { prepareSynchronously() }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.transactionAuthor = "app"
        container.viewContext.undoManager = UndoManager()
    }

    /// Opens the live stores without blocking SwiftUI's first frame. Store loading and
    /// lightweight migration run on Core Data's queues while the app shows a launch view.
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

    private func configureDescriptions(cloudEnabled: Bool) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let privateStore = Self.description(
            url: support.appendingPathComponent("BigBeautiful-private.sqlite"),
            scope: .private,
            cloudEnabled: cloudEnabled
        )
        let sharedStore = Self.description(
            url: support.appendingPathComponent("BigBeautiful-shared.sqlite"),
            scope: .shared,
            cloudEnabled: cloudEnabled
        )
        container.persistentStoreDescriptions = [privateStore, sharedStore]
    }

    private func prepareSynchronously() {
        let cloudError = loadStoresSynchronously()
        if let cloudError, prefersCloudSync {
            removeLoadedStores()
            configureDescriptions(cloudEnabled: false)
            loadError = loadStoresSynchronously() ?? cloudError
            isCloudSyncActive = false
        } else {
            loadError = cloudError
            isCloudSyncActive = prefersCloudSync && cloudError == nil
        }
        isReady = !container.persistentStoreCoordinator.persistentStores.isEmpty
    }

    @MainActor
    private func prepareAsynchronously() async {
        let cloudError = await loadStoresAsynchronously()
        if let cloudError, prefersCloudSync {
            removeLoadedStores()
            configureDescriptions(cloudEnabled: false)
            loadError = await loadStoresAsynchronously() ?? cloudError
            isCloudSyncActive = false
        } else {
            loadError = cloudError
            isCloudSyncActive = prefersCloudSync && cloudError == nil
        }
        isReady = !container.persistentStoreCoordinator.persistentStores.isEmpty
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

    private func removeLoadedStores() {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
    }

    func save() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        try context.save()
    }

    func existingShare(for object: NSManagedObject) throws -> CKShare? {
        if object.objectID.isTemporaryID {
            try object.managedObjectContext?.obtainPermanentIDs(for: [object])
        }
        return try container.fetchShares(matching: [object.objectID])[object.objectID]
    }

    func accept(_ metadata: CKShare.Metadata) {
        let store = container.persistentStoreCoordinator.persistentStores.first { store in
            store.url?.lastPathComponent.contains("-shared") == true
        }
        guard let store else {
            notifyFailure("The shared iCloud log could not be opened because its local shared store is unavailable.")
            return
        }
        container.acceptShareInvitations(from: [metadata], into: store) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.notifyFailure("The iCloud invitation could not be accepted. \(error.localizedDescription)")
                } else {
                    NotificationCenter.default.post(name: .cloudShareWasAccepted, object: self)
                }
            }
        }
    }

    private func notifyFailure(_ message: String) {
        NotificationCenter.default.post(
            name: .persistenceDidFail,
            object: self,
            userInfo: [PersistenceNotificationKey.message: message]
        )
    }

    private static func description(url: URL, scope: CKDatabase.Scope, cloudEnabled: Bool) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if cloudEnabled {
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudContainerIdentifier)
            options.databaseScope = scope
            description.cloudKitContainerOptions = options
        }
        return description
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let metadata = connectionOptions.cloudKitShareMetadata else { return }
        accept(metadata)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        accept(cloudKitShareMetadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            await PersistenceController.shared.prepare()
            PersistenceController.shared.accept(metadata)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static func sceneConfiguration(for role: UISceneSession.Role) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        Self.sceneConfiguration(for: connectingSceneSession.role)
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
