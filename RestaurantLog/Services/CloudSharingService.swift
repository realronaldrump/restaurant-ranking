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

    typealias ExistingPayload = (CircleEntity, PersistenceController) throws -> SharePayload?
    typealias NewPayload = (CircleEntity, PersistenceController) async throws -> SharePayload

    private let existingPayload: ExistingPayload
    private let newPayload: NewPayload

    init(
        existingPayload: @escaping ExistingPayload = { circle, persistence in
            guard let share = try persistence.existingShare(for: circle) else { return nil }
            return SharePayload(
                share: share,
                container: CKContainer(identifier: PersistenceController.cloudContainerIdentifier)
            )
        },
        newPayload: @escaping NewPayload = { circle, persistence in
            let (_, share, cloudContainer) = try await persistence.container.share([circle], to: nil)
            return SharePayload(share: share, container: cloudContainer)
        }
    ) {
        self.existingPayload = existingPayload
        self.newPayload = newPayload
    }

    func payload(for circle: CircleEntity, persistence: PersistenceController) async throws -> SharePayload {
        let payload: SharePayload
        if let existing = try existingPayload(circle, persistence) {
            payload = existing
        } else {
            payload = try await newPayload(circle, persistence)
        }
        payload.share[CKShare.SystemFieldKey.title] = "\(circle.name): Big Beautiful Restaurant Log" as CKRecordValue
        payload.share.publicPermission = .none
        return payload
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
