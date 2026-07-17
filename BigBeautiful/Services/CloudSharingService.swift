import CloudKit
import CoreData
import SwiftUI
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
}

@MainActor
final class CloudSharingService {
    static let shared = CloudSharingService()

    func payload(for circle: CircleEntity, persistence: PersistenceController) async throws -> SharePayload {
        let (_, share, cloudContainer) = try await persistence.container.share([circle], to: nil)
        share[CKShare.SystemFieldKey.title] = "\(circle.name) — Big Beautiful Restaurant Log" as CKRecordValue
        share.publicPermission = .none
        return SharePayload(share: share, container: cloudContainer)
    }
}

struct CloudSharingController: UIViewControllerRepresentable {
    let payload: SharePayload

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: payload.share, container: payload.container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}
}
