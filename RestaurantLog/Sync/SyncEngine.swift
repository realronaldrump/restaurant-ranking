import CoreData
import CryptoKit
import Foundation
import OSLog

extension Notification.Name {
    /// Posted after remote records have been written into the local store.
    /// Background-context saves do not raise `.NSPersistentStoreRemoteChange`
    /// in the same process, so the store is told explicitly to reload.
    static let syncDidApplyRemoteChanges = Notification.Name("RestaurantLog.syncDidApplyRemoteChanges")
    /// A circle this device had never seen appeared in a pull, which happens
    /// when someone accepts an invitation here.
    static let circleDidArriveFromSync = Notification.Name("RestaurantLog.circleDidArriveFromSync")
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case upToDate(Date)
    case offline(String)
    case failed(String)
    case disabled

    var isBusy: Bool { self == .syncing }
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .idle: return "Waiting"
        case .syncing: return "Syncing…"
        case let .upToDate(date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Updated \(formatter.localizedString(for: date, relativeTo: .now))"
        case .offline: return "Offline — saved on this iPhone"
        case .failed: return "Needs attention"
        case .disabled: return "Off"
        }
    }
}

struct SyncOutcome: Equatable {
    var pushed = 0
    var applied = 0
    var deletedLocally = 0
    var tombstoned = 0
    var conflicts = 0
    var photosUploaded = 0
    var photosDownloaded = 0
    var photosDeleted = 0

    var madeLocalChanges: Bool { applied > 0 || deletedLocally > 0 || photosDownloaded > 0 }
}

enum SyncPhotoCleanup {
    static func deletionCandidates(
        plannedKeys: [SyncKey],
        remote: [SyncKey: DecodedSyncRecord]
    ) -> Set<UUID> {
        let plannedPhotoIDs = plannedKeys.lazy
            .filter { $0.kind == .photo }
            .map(\.id)
        let remoteTombstoneIDs = remote.lazy.compactMap { key, record in
            key.kind == .photo && record.deleted ? key.id : nil
        }
        return Set(plannedPhotoIDs).union(remoteTombstoneIDs)
    }

    static func pending(
        candidates: Set<UUID>,
        completed: Set<UUID>,
        livePhotoIDs: Set<UUID>
    ) -> Set<UUID> {
        candidates.subtracting(completed.subtracting(livePhotoIDs))
    }

    static func completedAfterReconcilingLivePhotos(
        completed: Set<UUID>,
        livePhotoIDs: Set<UUID>
    ) -> Set<UUID> {
        completed.subtracting(livePhotoIDs)
    }
}

/// Advances only through rows this build understood. An unknown or unreadable
/// row remains inside future overlap windows so an app update or repaired key
/// can recover it instead of silently moving the watermark beyond it.
struct SyncWatermarkTracker {
    private let startingValue: Int64
    private var highestProcessed: Int64
    private var earliestSkipped: Int64?

    init(startingAt value: Int64) {
        startingValue = value
        highestProcessed = value
    }

    mutating func processed(_ value: Int64) {
        highestProcessed = max(highestProcessed, value)
    }

    mutating func skipped(_ value: Int64) {
        earliestSkipped = min(earliestSkipped ?? value, value)
    }

    var value: Int64 {
        max(startingValue, min(highestProcessed, earliestSkipped ?? highestProcessed))
    }
}

/// Drives one sync pass: pull, merge, apply, push, then photo blobs.
///
/// The sequence is deliberately pull-before-push. Applying what peers already
/// committed before uploading local edits means a conflict is decided against
/// the freshest server state this device has seen, and it keeps the local graph
/// referentially complete before anything is published from it.
actor SyncEngine {
    /// Re-examine a few seconds either side of the watermark. Postgres assigns
    /// `updated_ms` at row write time, so two transactions can commit in an
    /// order that does not match their timestamps; overlapping the window
    /// guarantees a peer write is never stepped over. Re-seen records are
    /// fingerprint-identical and cost nothing.
    private static let watermarkOverlapMS: Int64 = 5_000

    private let configuration: SyncConfiguration
    private let client: SupabaseClient
    private let container: NSPersistentContainer
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.davis.bigbeautifulranking",
        category: "Sync"
    )

    private var inFlight: Task<SyncOutcome, Error>?

    init(configuration: SyncConfiguration, container: NSPersistentContainer, client: SupabaseClient? = nil) {
        self.configuration = configuration
        self.container = container
        self.client = client ?? SupabaseClient(configuration: configuration)
    }

    var supabase: SupabaseClient { client }

    // MARK: - Entry point

    /// Coalesces overlapping requests: a save that lands while a pass is running
    /// joins that pass rather than starting a second one against the same rows.
    func synchronize(circleID: UUID) async throws -> SyncOutcome {
        if let inFlight { return try await inFlight.value }

        let task = Task { () throws -> SyncOutcome in
            try await run(circleID: circleID)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Lifecycle operations (leave, reset, account deletion) must not race a
    /// pass that can republish rows after the server copy was retired.
    func cancelSynchronization() async {
        guard let task = inFlight else { return }
        task.cancel()
        _ = await task.result
        inFlight = nil
    }

    private func run(circleID: UUID) async throws -> SyncOutcome {
        guard try await client.restore() != nil else { throw SyncError.notSignedIn }
        guard let key = CircleKeychain.key(for: circleID) else { throw SyncError.circleKeyMissing }

        var baseline = SyncBaselineStore.load(circleID: circleID)
        var outcome = SyncOutcome()

        // 1. Pull everything changed since the watermark, with overlap.
        let since = max(0, baseline.watermark - Self.watermarkOverlapMS)
        let (remote, highestSeen) = try await pullAll(circleID: circleID, since: since, key: key)

        // 2. Read the local graph.
        let context = container.newBackgroundContext()

        let snapshot = try await context.perform {
            // A private-queue context's mutable configuration is Core Data
            // state too. Configure it on its own queue so concurrency checking
            // cannot terminate the app during a sync pass.
            context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
            context.transactionAuthor = "sync"
            return try SyncSnapshotBuilder.build(circleID: circleID, in: context)
        }

        // 3. Decide.
        let plan = SyncPlanner.plan(
            local: snapshot.records,
            remote: remote,
            baseline: baseline.keyedFingerprints
        )
        outcome.conflicts = plan.conflicts.count
        var deferredReferences = false
        if !plan.conflicts.isEmpty {
            logger.notice("Sync resolved \(plan.conflicts.count, privacy: .public) record conflict(s).")
        }

        // 4. Apply remote changes locally.
        if !plan.apply.isEmpty || !plan.deleteLocally.isEmpty {
            let applyResult = try await context.perform {
                let result = try SyncApplier.apply(
                    records: remote,
                    applying: plan.apply,
                    deleting: plan.deleteLocally,
                    circleID: circleID,
                    in: context
                )
                if context.hasChanges { try context.save() }
                return result
            }
            outcome.applied = applyResult.applied
            outcome.deletedLocally = applyResult.deleted
            deferredReferences = !applyResult.deferredKeys.isEmpty
        }

        // 5. Publish local changes.
        var outgoing: [SupabaseClient.OutgoingRecord] = []
        for syncKey in plan.push {
            guard let record = snapshot.records[syncKey] else { continue }
            let sealed = try CircleCrypto.seal(
                record.payload,
                with: key,
                authenticating: CircleCrypto.recordIdentity(circleID: circleID, kind: syncKey.kind, id: syncKey.id)
            )
            outgoing.append(SupabaseClient.OutgoingRecord(
                circleID: circleID,
                kind: syncKey.kind.rawValue,
                id: syncKey.id,
                payload: sealed.base64EncodedString(),
                deleted: false,
                deviceID: SyncDevice.identifier
            ))
        }
        for syncKey in plan.tombstone {
            outgoing.append(SupabaseClient.OutgoingRecord(
                circleID: circleID,
                kind: syncKey.kind.rawValue,
                id: syncKey.id,
                payload: nil,
                deleted: true,
                deviceID: SyncDevice.identifier
            ))
        }
        if !outgoing.isEmpty {
            try await client.pushRecords(outgoing)
            outcome.pushed = plan.push.count
            outcome.tombstoned = plan.tombstone.count
        }

        // Photo bytes are separate Storage objects, so tombstoning their
        // metadata is not enough. Remove both variants before accepting the new
        // baseline; a failure leaves this pass retryable and the operation is
        // idempotent if another device already completed it.
        let deletionCandidates = SyncPhotoCleanup.deletionCandidates(
            plannedKeys: plan.tombstone + plan.deleteLocally,
            remote: remote
        )
        // Remote tombstones keep a failed Storage cleanup retryable after local
        // metadata is gone. The completed-ID ledger suppresses repeat deletes
        // once both objects have been removed successfully.
        let deletedPhotoIDs = SyncPhotoCleanup.pending(
            candidates: deletionCandidates,
            completed: baseline.cleanedPhotoIDs,
            livePhotoIDs: snapshot.photoIDs
        )
        for photoID in deletedPhotoIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try await client.deletePhoto(circleID: circleID, objectKey: "\(photoID.uuidString).full")
            try await client.deletePhoto(circleID: circleID, objectKey: "\(photoID.uuidString).thumb")
            baseline.uploadedPhotoIDs.remove(photoID)
            baseline.downloadedPhotoIDs.remove(photoID)
            baseline.cleanedPhotoIDs.insert(photoID)
            outcome.photosDeleted += 1
        }

        // 6. Rebuild the baseline from what the store actually holds now.
        //    Setters normalise some values (companion lists and tag arrays are
        //    sorted and de-duplicated), so trusting the payload we sent would
        //    leave a fingerprint that never matches on the next pass.
        let settled = try await context.perform {
            try SyncSnapshotBuilder.build(circleID: circleID, in: context)
        }
        baseline.cleanedPhotoIDs = SyncPhotoCleanup.completedAfterReconcilingLivePhotos(
            completed: baseline.cleanedPhotoIDs,
            livePhotoIDs: settled.photoIDs
        )

        // Where storing a remote record produced a different value than the one
        // that arrived, publish the stored version. Without this the two sides
        // would disagree forever and every pass would re-apply the same record.
        var reconciliation: [SupabaseClient.OutgoingRecord] = []
        for syncKey in plan.apply {
            guard let stored = settled.records[syncKey],
                  let received = remote[syncKey]?.fingerprint,
                  stored.fingerprint != received else { continue }
            let sealed = try CircleCrypto.seal(
                stored.payload,
                with: key,
                authenticating: CircleCrypto.recordIdentity(circleID: circleID, kind: syncKey.kind, id: syncKey.id)
            )
            reconciliation.append(SupabaseClient.OutgoingRecord(
                circleID: circleID,
                kind: syncKey.kind.rawValue,
                id: syncKey.id,
                payload: sealed.base64EncodedString(),
                deleted: false,
                deviceID: SyncDevice.identifier
            ))
        }
        if !reconciliation.isEmpty {
            logger.notice("Republished \(reconciliation.count, privacy: .public) record(s) that changed shape on the way in.")
            try await client.pushRecords(reconciliation)
            outcome.pushed += reconciliation.count
        }

        baseline.replaceFingerprints(with: settled.records)
        // A missing parent may have fallen outside the current delta window.
        // Force the next pass to pull the complete circle rather than accepting
        // a child with a broken relationship or moving beyond it forever.
        baseline.watermark = deferredReferences ? 0 : max(baseline.watermark, highestSeen)

        // 7. Photo bytes, which never travel with the record stream.
        let photoResult = try await synchronizePhotos(
            circleID: circleID,
            key: key,
            snapshot: settled,
            baseline: &baseline,
            context: context
        )
        outcome.photosUploaded = photoResult.uploaded
        outcome.photosDownloaded = photoResult.downloaded

        try SyncBaselineStore.save(baseline)

        if outcome.madeLocalChanges {
            await MainActor.run {
                NotificationCenter.default.post(name: .syncDidApplyRemoteChanges, object: nil)
            }
        }
        return outcome
    }

    // MARK: - Pull

    private func pullAll(
        circleID: UUID,
        since: Int64,
        key: SymmetricKey
    ) async throws -> ([SyncKey: DecodedSyncRecord], Int64) {
        var decoded: [SyncKey: DecodedSyncRecord] = [:]
        var watermark = SyncWatermarkTracker(startingAt: since)
        var cursor: SupabaseClient.PullCursor?

        while true {
            let page = try await client.pullRecords(circleID: circleID, since: since, after: cursor)
            if page.isEmpty { break }

            for row in page {
                guard let kind = SyncKind(rawValue: row.kind) else {
                    // A newer build of the app added a record type this one does
                    // not know. Skipping keeps the rest of the sync working.
                    logger.notice("Skipping unknown record kind \(row.kind, privacy: .public).")
                    watermark.skipped(row.updatedMS)
                    continue
                }
                let syncKey = SyncKey(kind: kind, id: row.id)

                if row.deleted {
                    decoded[syncKey] = DecodedSyncRecord(
                        key: syncKey, payload: nil, fingerprint: nil, deleted: true,
                        updatedMS: row.updatedMS, deviceID: row.deviceID
                    )
                    watermark.processed(row.updatedMS)
                    continue
                }
                guard let encoded = row.payload, let sealed = Data(base64Encoded: encoded) else {
                    logger.error("Malformed encrypted payload for \(row.kind, privacy: .public); skipping it.")
                    watermark.skipped(row.updatedMS)
                    continue
                }
                guard let plaintext = try? CircleCrypto.open(
                    sealed,
                    with: key,
                    authenticating: CircleCrypto.recordIdentity(circleID: circleID, kind: kind, id: row.id)
                ) else {
                    // Wrong key for this circle, or a corrupted row. Neither is
                    // fixable by retrying, and neither should stop the pass.
                    logger.error("Could not decrypt \(row.kind, privacy: .public) record; skipping it.")
                    watermark.skipped(row.updatedMS)
                    continue
                }
                decoded[syncKey] = DecodedSyncRecord(
                    key: syncKey,
                    payload: plaintext,
                    fingerprint: SyncPayloadCodec.fingerprint(plaintext),
                    deleted: false,
                    updatedMS: row.updatedMS,
                    deviceID: row.deviceID
                )
                watermark.processed(row.updatedMS)
            }

            if page.count < SupabaseClient.pullPageSize { break }
            guard let last = page.last else { break }
            cursor = SupabaseClient.PullCursor(
                updatedMS: last.updatedMS,
                kind: last.kind,
                id: last.id
            )
        }
        return (decoded, watermark.value)
    }

    // MARK: - Photos

    private struct PhotoSyncResult {
        var uploaded = 0
        var downloaded = 0
    }

    /// Uploads blobs this device holds but has not published, and fetches blobs
    /// for photo records that arrived without their bytes.
    ///
    /// Failures here are logged and swallowed on purpose: a missing image is a
    /// degraded photo, not a broken log, and it must not prevent ratings and
    /// visits from converging.
    private func synchronizePhotos(
        circleID: UUID,
        key: SymmetricKey,
        snapshot: SyncSnapshot,
        baseline: inout SyncBaseline,
        context: NSManagedObjectContext
    ) async throws -> PhotoSyncResult {
        var result = PhotoSyncResult()

        let pendingUploads = snapshot.photoIDs.subtracting(baseline.uploadedPhotoIDs)
        for photoID in pendingUploads.sorted(by: { $0.uuidString < $1.uuidString }) {
            let blobs: (full: Data?, thumbnail: Data?) = try await context.perform {
                let request = NSFetchRequest<PhotoEntity>(entityName: "PhotoEntity")
                request.predicate = NSPredicate(format: "id == %@", photoID as CVarArg)
                request.fetchLimit = 1
                guard let photo = try context.fetch(request).first else { return (nil, nil) }
                return (photo.fullData, photo.thumbnailData)
            }
            guard let full = blobs.full else { continue }

            do {
                try await client.uploadPhoto(
                    circleID: circleID,
                    objectKey: "\(photoID.uuidString).full",
                    sealed: try CircleCrypto.seal(
                        full,
                        with: key,
                        authenticating: CircleCrypto.photoIdentity(circleID: circleID, photoID: photoID, variant: "full")
                    )
                )
                if let thumbnail = blobs.thumbnail {
                    try await client.uploadPhoto(
                        circleID: circleID,
                        objectKey: "\(photoID.uuidString).thumb",
                        sealed: try CircleCrypto.seal(
                            thumbnail,
                            with: key,
                            authenticating: CircleCrypto.photoIdentity(circleID: circleID, photoID: photoID, variant: "thumb")
                        )
                    )
                }
                baseline.uploadedPhotoIDs.insert(photoID)
                result.uploaded += 1
            } catch {
                logger.error("Photo upload failed for \(photoID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Photo records whose bytes are still missing on this device.
        let missing: [UUID] = try await context.perform {
            let request = NSFetchRequest<PhotoEntity>(entityName: "PhotoEntity")
            request.predicate = NSPredicate(
                format: "visit.circle.id == %@ AND fullData == nil",
                circleID as CVarArg
            )
            return try context.fetch(request).map(\.id)
        }

        for photoID in missing where !baseline.downloadedPhotoIDs.contains(photoID) {
            do {
                guard let sealedFull = try await client.downloadPhoto(
                    circleID: circleID,
                    objectKey: "\(photoID.uuidString).full"
                ) else { continue }
                let full = try CircleCrypto.open(
                    sealedFull,
                    with: key,
                    authenticating: CircleCrypto.photoIdentity(circleID: circleID, photoID: photoID, variant: "full")
                )

                let thumbnail: Data? = if let sealedThumb = try await client.downloadPhoto(
                    circleID: circleID,
                    objectKey: "\(photoID.uuidString).thumb"
                ) {
                    try? CircleCrypto.open(
                        sealedThumb,
                        with: key,
                        authenticating: CircleCrypto.photoIdentity(circleID: circleID, photoID: photoID, variant: "thumb")
                    )
                } else {
                    nil
                }

                try await context.perform {
                    let request = NSFetchRequest<PhotoEntity>(entityName: "PhotoEntity")
                    request.predicate = NSPredicate(format: "id == %@", photoID as CVarArg)
                    request.fetchLimit = 1
                    guard let photo = try context.fetch(request).first else { return }
                    photo.fullData = full
                    if let thumbnail { photo.thumbnailData = thumbnail }
                    if context.hasChanges { try context.save() }
                }
                baseline.downloadedPhotoIDs.insert(photoID)
                result.downloaded += 1
            } catch {
                logger.error("Photo download failed for \(photoID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return result
    }
}
