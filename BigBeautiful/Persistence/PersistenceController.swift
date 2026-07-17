import CloudKit
import CoreData
import UIKit

final class PersistenceController {
    static let shared: PersistenceController = {
        let arguments = ProcessInfo.processInfo.arguments
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return PersistenceController(
            inMemory: isRunningUnitTests || arguments.contains("-resetForUITests"),
            cloudEnabled: !isRunningUnitTests && !arguments.contains("-disableCloudKit") && !arguments.contains("-resetForUITests")
        )
    }()
    static let cloudContainerIdentifier = "iCloud.com.davis.bigbeautifulranking"

    let container: NSPersistentCloudKitContainer
    private(set) var loadError: Error?

    init(inMemory: Bool = false, cloudEnabled: Bool = true) {
        container = NSPersistentCloudKitContainer(name: "BigBeautiful", managedObjectModel: ManagedObjectModel.make())

        if inMemory {
            let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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

        container.loadPersistentStores { [weak self] _, error in
            if let error {
                self?.loadError = error
                assertionFailure("Persistent store failed to load: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.transactionAuthor = "app"
        container.viewContext.undoManager = UndoManager()
    }

    func save() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        try context.save()
    }

    func accept(_ metadata: CKShare.Metadata) {
        let store = container.persistentStoreCoordinator.persistentStores.first { store in
            store.url?.lastPathComponent.contains("-shared") == true
        }
        guard let store else { return }
        container.acceptShareInvitations(from: [metadata], into: store) { _, error in
            if let error { print("Could not accept CloudKit share: \(error.localizedDescription)") }
        }
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

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        PersistenceController.shared.accept(cloudKitShareMetadata)
    }
}
