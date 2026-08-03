import Foundation

/// What one sync pass should do, decided before anything is written.
///
/// This type is deliberately free of Core Data, URLSession, and crypto so the
/// merge rules can be unit tested directly. Everything it needs is three
/// dictionaries: what this device holds, what the server sent, and what the two
/// last agreed on.
struct SyncPlan: Equatable {
    /// Remote records to write into the local store.
    var apply: [SyncKey] = []
    /// Local records to seal and upload.
    var push: [SyncKey] = []
    /// Records deleted on this device; upload a tombstone.
    var tombstone: [SyncKey] = []
    /// Records tombstoned elsewhere; delete locally.
    var deleteLocally: [SyncKey] = []
    /// Records that changed on both sides since the last agreement.
    var conflicts: [SyncKey] = []
    var isEmpty: Bool {
        apply.isEmpty && push.isEmpty && tombstone.isEmpty && deleteLocally.isEmpty
    }
}

enum SyncPlanner {
    /// Conflict rule: when a record changed on both sides since the last
    /// agreement, this device's version is kept and pushed.
    ///
    /// The domain makes that rule safe. Ratings, dish entries, comparisons and
    /// participants are all keyed to a `personID`, so two diners edit different
    /// rows almost by construction; the genuinely shared rows are restaurant
    /// details and dish names, where a stale overwrite costs one re-edit and
    /// never loses a visit. Preferring the local side also means the person
    /// looking at the screen sees their own change survive, which is the
    /// behaviour they can actually reason about.
    static func plan(
        local: [SyncKey: LocalSyncRecord],
        remote: [SyncKey: DecodedSyncRecord],
        baseline: [SyncKey: String]
    ) -> SyncPlan {
        var plan = SyncPlan()

        var keys = Set(local.keys)
        keys.formUnion(remote.keys)
        keys.formUnion(baseline.keys)

        for key in keys.sorted(by: order) {
            let localRecord = local[key]
            let remoteRecord = remote[key]
            let agreed = baseline[key]

            switch (localRecord, remoteRecord) {
            case let (.some(mine), .none):
                // Not in this pull window, so the server's copy is whatever we
                // last agreed on.
                if mine.fingerprint != agreed { plan.push.append(key) }

            case let (.none, .some(theirs)):
                if theirs.deleted {
                    // Gone on both sides. Rebuilding the baseline from the
                    // settled local snapshot drops the old fingerprint.
                } else if agreed == nil {
                    plan.apply.append(key)
                } else if theirs.fingerprint == agreed {
                    // We deleted it and nobody else touched it.
                    plan.tombstone.append(key)
                } else {
                    // Deleted here, edited there. Restoring is recoverable;
                    // deleting someone else's fresh edit is not.
                    plan.conflicts.append(key)
                    plan.apply.append(key)
                }

            case (.none, .none):
                // `remote` contains only the current delta window. If this key
                // was in the baseline but is absent locally, the local copy was
                // deleted while the unchanged server row fell outside that
                // window. Publish a tombstone; treating absence as "gone on both
                // sides" silently abandons nearly every ordinary deletion.
                if agreed != nil { plan.tombstone.append(key) }

            case let (.some(mine), .some(theirs)):
                if theirs.deleted {
                    if mine.fingerprint == agreed {
                        plan.deleteLocally.append(key)
                    } else {
                        plan.conflicts.append(key)
                        plan.push.append(key)
                    }
                    continue
                }
                if mine.fingerprint == theirs.fingerprint {
                    continue // already identical; the baseline refresh records it
                }
                let localChanged = mine.fingerprint != agreed
                let remoteChanged = theirs.fingerprint != agreed
                switch (localChanged, remoteChanged) {
                case (true, true):
                    plan.conflicts.append(key)
                    plan.push.append(key)
                case (true, false):
                    plan.push.append(key)
                case (false, true):
                    plan.apply.append(key)
                case (false, false):
                    continue
                }
            }
        }

        // Apply parents before children, delete children before parents.
        plan.apply.sort(by: applyOrder)
        plan.deleteLocally.sort(by: deleteOrder)
        return plan
    }

    private static func order(_ lhs: SyncKey, _ rhs: SyncKey) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func applyOrder(_ lhs: SyncKey, _ rhs: SyncKey) -> Bool {
        let left = SyncKind.applyOrder.firstIndex(of: lhs.kind) ?? 0
        let right = SyncKind.applyOrder.firstIndex(of: rhs.kind) ?? 0
        if left != right { return left < right }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func deleteOrder(_ lhs: SyncKey, _ rhs: SyncKey) -> Bool {
        let left = SyncKind.applyOrder.firstIndex(of: lhs.kind) ?? 0
        let right = SyncKind.applyOrder.firstIndex(of: rhs.kind) ?? 0
        if left != right { return left > right }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - Baseline

/// The last state this device and the server agreed on.
///
/// Fingerprints are content hashes, not timestamps, so a record that was
/// rewritten with identical values produces no sync traffic at all.
struct SyncBaseline: Codable, Equatable {
    var circleID: UUID
    var watermark: Int64
    var fingerprints: [String: String]
    var uploadedPhotoIDs: Set<UUID>
    var downloadedPhotoIDs: Set<UUID>
    /// Storage deletions already completed by this device. Remote tombstones
    /// remain in the pull overlap window, so this prevents every later pass
    /// from issuing the same object deletion again.
    var cleanedPhotoIDs: Set<UUID>
    /// Activity is quiet during the first successful hydration of an existing
    /// circle, rather than presenting the whole history as new.
    var activitySeeded: Bool

    init(
        circleID: UUID,
        watermark: Int64 = 0,
        fingerprints: [String: String] = [:],
        uploadedPhotoIDs: Set<UUID> = [],
        downloadedPhotoIDs: Set<UUID> = [],
        cleanedPhotoIDs: Set<UUID> = [],
        activitySeeded: Bool = false
    ) {
        self.circleID = circleID
        self.watermark = watermark
        self.fingerprints = fingerprints
        self.uploadedPhotoIDs = uploadedPhotoIDs
        self.downloadedPhotoIDs = downloadedPhotoIDs
        self.cleanedPhotoIDs = cleanedPhotoIDs
        self.activitySeeded = activitySeeded
    }

    private enum CodingKeys: String, CodingKey {
        case circleID, watermark, fingerprints, uploadedPhotoIDs, downloadedPhotoIDs, cleanedPhotoIDs, activitySeeded
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        circleID = try values.decode(UUID.self, forKey: .circleID)
        watermark = try values.decode(Int64.self, forKey: .watermark)
        fingerprints = try values.decode([String: String].self, forKey: .fingerprints)
        uploadedPhotoIDs = try values.decode(Set<UUID>.self, forKey: .uploadedPhotoIDs)
        downloadedPhotoIDs = try values.decode(Set<UUID>.self, forKey: .downloadedPhotoIDs)
        // Baselines from released builds predate this field. Treating them as
        // having no completed cleanup makes the upgrade safe and retryable.
        cleanedPhotoIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .cleanedPhotoIDs) ?? []
        activitySeeded = try values.decodeIfPresent(Bool.self, forKey: .activitySeeded) ?? false
    }

    static func encodeKey(_ key: SyncKey) -> String {
        "\(key.kind.rawValue):\(key.id.uuidString)"
    }

    static func decodeKey(_ raw: String) -> SyncKey? {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let kind = SyncKind(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        return SyncKey(kind: kind, id: id)
    }

    var keyedFingerprints: [SyncKey: String] {
        var result: [SyncKey: String] = [:]
        result.reserveCapacity(fingerprints.count)
        for (raw, fingerprint) in fingerprints {
            if let key = Self.decodeKey(raw) { result[key] = fingerprint }
        }
        return result
    }

    mutating func replaceFingerprints(with records: [SyncKey: LocalSyncRecord]) {
        fingerprints = Dictionary(
            uniqueKeysWithValues: records.map { (Self.encodeKey($0.key), $0.value.fingerprint) }
        )
    }
}

/// Baseline storage. A plain JSON file in Application Support rather than a
/// Core Data entity: it is device-local bookkeeping that must never itself sync,
/// and losing it is harmless — the next pass rebuilds it from a full pull.
enum SyncBaselineStore {
    private static let maximumBaselineBytes = 32 * 1_024 * 1_024
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func url(for circleID: UUID) -> URL {
        directory.appendingPathComponent("baseline-\(circleID.uuidString).json")
    }

    static func load(circleID: UUID) -> SyncBaseline {
        let fileURL = url(for: circleID)
        guard let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= maximumBaselineBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= maximumBaselineBytes,
              let baseline = try? JSONDecoder().decode(SyncBaseline.self, from: data),
              baseline.circleID == circleID
        else { return SyncBaseline(circleID: circleID) }
        return baseline
    }

    static func save(_ baseline: SyncBaseline) throws {
        let data = try JSONEncoder().encode(baseline)
        try data.write(to: url(for: baseline.circleID), options: .atomic)
    }

    static func reset(circleID: UUID) {
        try? FileManager.default.removeItem(at: url(for: circleID))
    }
}
