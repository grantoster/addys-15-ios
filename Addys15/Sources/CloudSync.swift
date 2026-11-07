import CloudKit
import Foundation

/// Sync through the app's CloudKit public database, so Addy's iPad and Mom's iPhone can share
/// even with different Apple IDs. Everything is fetched by record name (no queries), and each
/// device only ever writes its own records:
///   addy-<code>   (A15AddyIndex) – written by Addy's device: item id -> last change time
///   item-<uuid>   (A15Item)      – written by Addy's device: the listing and up to 4 photos
///   mom-<code>    (A15MomLedger) – written by Mom's device: posted / sold / removed, price changes
struct CloudSync {
    private var container: CKContainer { CKContainer.default() }
    private var db: CKDatabase { container.publicCloudDatabase }

    static let itemType = "A15Item"
    static let addyType = "A15AddyIndex"
    static let momType = "A15MomLedger"
    static let maxPhotos = 4

    func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    /// Fetches records by name; names that don't exist yet are simply missing from the result.
    func fetch(_ names: [String]) async throws -> [String: CKRecord] {
        var out: [String: CKRecord] = [:]
        for chunk in stride(from: 0, to: names.count, by: 100).map({ Array(names[$0..<min($0 + 100, names.count)]) }) {
            let results = try await db.records(for: chunk.map { CKRecord.ID(recordName: $0) })
            for (id, result) in results {
                switch result {
                case .success(let rec): out[id.recordName] = rec
                case .failure(let error):
                    if (error as? CKError)?.code == .unknownItem { continue }
                    throw error
                }
            }
        }
        return out
    }

    func saveJSON(type: String, name: String, json: String) async throws {
        let rec = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name))
        rec["json"] = json
        try await save(rec)
    }

    func saveItem(id: String, json: String, photos: [URL]) async throws {
        let rec = CKRecord(recordType: Self.itemType, recordID: CKRecord.ID(recordName: id))
        rec["json"] = json
        for i in 0..<Self.maxPhotos {
            if i < photos.count {
                rec["photo\(i)"] = CKAsset(fileURL: photos[i])
            } else {
                rec["photo\(i)"] = nil as CKAsset?
            }
        }
        try await save(rec)
    }

    /// Saves the whole record, replacing what's on the server (each record has one writer).
    private func save(_ rec: CKRecord) async throws {
        let (results, _) = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: false)
        for (_, r) in results {
            if case .failure(let e) = r { throw e }
        }
    }

    static func friendly(_ error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings so this device can sync."
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "Can't reach iCloud right now. It will sync when it's back online."
            case .quotaExceeded: return "iCloud storage for the app is full."
            case .permissionFailure:
                return "This family code is already used by another Apple ID for this role. Set up a new code on both devices (Settings, then Pairing)."
            default: break
            }
        }
        return "Sync problem: \(error.localizedDescription)"
    }
}
