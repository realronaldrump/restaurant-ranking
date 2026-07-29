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

    var description: String {
        switch self {
        case .idle: "Waiting"
        case .syncing: "Syncing…"
        case let .upToDate(date): "Updated \(Self.formatter.localizedString(for: date, relativeTo: .now))"
        case .offline: "Offline — saved on this iPhone"
        case .failed: "Needs attention"
        case .disabled: "Off"
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

struct SyncOutcome: Equatable {
    var pushed = 0
    var applied = 0
    var deletedLocally = 0
    var tombstoned = 0
    var conflicts = 0
    var photosUploaded = 0
    var photosDownloaded = 0

    var madeLocalChanges: Bool { applied > 0 || deletedLocally > 0 || photosDownloaded > 0 }
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
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.transactionAuthor = "sync"

        let snapshot = try await context.perform {
            try SyncSnapshotBuilder.build(circleID: circleID, in: context)
        }

        // 3. Decide.
        let plan = SyncPlanner.plan(
            local: snapshot.records,
            remote: remote,
            baseline: baseline.keyedFingerprints
        )
        outcome.conflicts = plan.conflicts.count
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
        }

        // 5. Publish local changes.
        var outgoing: [SupabaseClient.OutgoingRecord] = []
        for syncKey in plan.push {
            guard let record = snapshot.records[syncKey] else { continue }
            let sealed = try CircleCrypto.seal(record.payload, with: key)
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

        // 6. Rebuild the baseline from what the store actually holds now.
        //    Setters normalise some values (companion lists and tag arrays are
        //    sorted and de-duplicated), so trusting the payload we sent would
        //    leave a fingerprint that never matches on the next pass.
        let settled = try await context.perform {
            try SyncSnapshotBuilder.build(circleID: circleID, in: context)
        }
        baseline.replaceFingerprints(with: settled.records)
        baseline.watermark = max(baseline.watermark, highestSeen)

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
        var highest = since
        var offset = 0

        while true {
            let page = try await client.pullRecords(circleID: circleID, since: since, offset: offset)
            if page.isEmpty { break }

            for row in page {
                highest = max(highest, row.updatedMS)
                guard let kind = SyncKind(rawValue: row.kind) else {
                    // A newer build of the app added a record type this one does
                    // not know. Skipping keeps the rest of the sync working.
                    logger.notice("Skipping unknown record kind \(row.kind, privacy: .public).")
                    continue
                }
                let syncKey = SyncKey(kind: kind, id: row.id)

                if row.deleted {
                    decoded[syncKey] = DecodedSyncRecord(
                        key: syncKey, payload: nil, fingerprint: nil, deleted: true,
                        updatedMS: row.updatedMS, deviceID: row.deviceID
                    )
                    continue
                }
                guard let encoded = row.payload, let sealed = Data(base64Encoded: encoded) else { continue }
                guard let plaintext = try? CircleCrypto.open(sealed, with: key) else {
                    // Wrong key for this circle, or a corrupted row. Neither is
                    // fixable by retrying, and neither should stop the pass.
                    logger.error("Could not decrypt \(row.kind, privacy: .public) record; skipping it.")
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
            }

            if page.count < SupabaseClient.pullPageSize { break }
            offset += page.count
        }
        return (decoded, highest)
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
                    sealed: try CircleCrypto.seal(full, with: key)
                )
                if let thumbnail = blobs.thumbnail {
                    try await client.uploadPhoto(
                        circleID: circleID,
                        objectKey: "\(photoID.uuidString).thumb",
                        sealed: try CircleCrypto.seal(thumbnail, with: key)
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
                let full = try CircleCrypto.open(sealedFull, with: key)

                var thumbnail: Data?
                if let sealedThumb = try await client.downloadPhoto(
                    circleID: circleID,
                    objectKey: "\(photoID.uuidString).thumb"
                ) {
                    thumbnail = try? CircleCrypto.open(sealedThumb, with: key)
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
