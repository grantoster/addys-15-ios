import SwiftUI
import UIKit
import CloudKit

@MainActor
@Observable
final class AppModel {
    // Settings (this device only)
    private(set) var role: Role?
    private(set) var code: String?
    private(set) var pickupLine: String
    private(set) var seenEarnedCents: Int

    // Shared data (cached on this device, synced through iCloud)
    private(set) var items: [String: Item] = [:]
    private(set) var addyIndex: [String: Double] = [:]
    private(set) var ledger = Ledger()
    private(set) var pendingUploads: Set<String> = []
    private var ledgerDirty = false

    // Sync status
    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var syncProblem: String?
    private(set) var photoVersion = 0

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let cloud = CloudSync()
    @ObservationIgnored private var imageCache: [String: UIImage] = [:]
    @ObservationIgnored private var pushingItems = false
    @ObservationIgnored private var pushingLedger = false

    init() {
        role = defaults.string(forKey: "role").flatMap(Role.init(rawValue:))
        code = defaults.string(forKey: "code")
        pickupLine = defaults.string(forKey: "pickupLine") ?? "Smoke-free home. Porch pickup available."
        seenEarnedCents = defaults.integer(forKey: "seenEarned")
        load()
    }

    // MARK: Settings

    func setUp(role: Role, code: String) {
        let changed = self.code != code
        self.role = role
        self.code = code
        defaults.set(role.rawValue, forKey: "role")
        defaults.set(code, forKey: "code")
        if changed {
            items = [:]; addyIndex = [:]; ledger = Ledger(); pendingUploads = []; ledgerDirty = false
            seenEarnedCents = 0; defaults.set(0, forKey: "seenEarned")
            persist()
        }
        Task { await refresh() }
    }

    /// Kid mode and grown-up mode on the same device; the family code and all data stay.
    func switchRole(_ r: Role) {
        guard let code else { return }
        setUp(role: r, code: code)
    }

    func setPickupLine(_ s: String) {
        pickupLine = s
        defaults.set(s, forKey: "pickupLine")
    }

    func markEarningsSeen() {
        seenEarnedCents = earnedCents
        defaults.set(seenEarnedCents, forKey: "seenEarned")
    }

    // MARK: Reading

    func stage(_ id: String) -> Stage { ledger.statuses[id]?.stage ?? .ready }
    func price(_ item: Item) -> Int? { ledger.statuses[item.id]?.priceCents ?? item.priceCents }
    func momSetPrice(_ id: String) -> Bool { ledger.statuses[id]?.priceCents != nil }

    var activeItems: [Item] {
        items.values.filter { stage($0.id) != .removed }.sorted { $0.createdAt > $1.createdAt }
    }
    func items(in s: Stage) -> [Item] {
        let list = items.values.filter { stage($0.id) == s }
        if s == .sold {
            return list.sorted { (ledger.statuses[$0.id]?.soldAt ?? .distantPast) > (ledger.statuses[$1.id]?.soldAt ?? .distantPast) }
        }
        return list.sorted { $0.createdAt > $1.createdAt }
    }
    func soldCents(_ id: String) -> Int? { stage(id) == .sold ? ledger.statuses[id]?.soldCents : nil }

    /// Addy's earnings: her 15% of each sale, added up.
    var earnedCents: Int { items(in: .sold).compactMap { soldCents($0.id) }.reduce(0) { $0 + Money.share($1) } }
    var soldTotalCents: Int { items(in: .sold).compactMap { soldCents($0.id) }.reduce(0, +) }

    // MARK: Photos

    static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Addys15", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let photosDir: URL = {
        let u = supportDir.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    func photoURL(_ id: String, _ n: Int) -> URL { Self.photosDir.appendingPathComponent("\(id)-\(n).jpg") }
    func photoURLs(_ item: Item) -> [URL] {
        (0..<item.photoCount).map { photoURL(item.id, $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func image(_ id: String, _ n: Int) -> UIImage? {
        _ = photoVersion
        let key = "\(id)-\(n)"
        if let i = imageCache[key] { return i }
        guard let i = UIImage(contentsOfFile: photoURL(id, n).path) else { return nil }
        imageCache[key] = i
        return i
    }
    private func dropCachedImages(_ id: String) {
        for n in 0..<CloudSync.maxPhotos { imageCache["\(id)-\(n)"] = nil }
        photoVersion += 1
    }

    // MARK: Addy's changes

    func buildItem(from d: Draft, result r: ListingResult) -> Item {
        let prices = r.comps.map(\.priceCents).filter { $0 > 0 }
        let suggested = prices.count >= 3 ? max(100, Money.medianDollar(prices)) : nil
        let photos = d.allPhotos
        return Item(id: d.id, createdAt: d.createdAt, updatedAt: Date(), kind: d.kind ?? .other,
                    brand: d.brand.trimmingCharacters(in: .whitespacesAndNewlines),
                    size: d.size ?? Sizes.unknown, color: d.color, itemName: d.itemName, gender: d.gender,
                    pieces: d.kind == .bundle ? d.pieces : 1, condition: d.condition ?? .gentlyUsed,
                    hasFlaws: d.hasFlaws ?? false, title: r.title, description: r.description, comps: r.comps,
                    suggestedPriceCents: suggested, priceCents: suggested, photoCount: photos.count)
    }

    func saveItem(_ item: Item, photos: [UIImage]) {
        for n in 0..<CloudSync.maxPhotos { try? FileManager.default.removeItem(at: photoURL(item.id, n)) }
        for (n, img) in photos.prefix(CloudSync.maxPhotos).enumerated() {
            try? img.jpegData(compressionQuality: 0.8)?.write(to: photoURL(item.id, n))
        }
        dropCachedImages(item.id)
        items[item.id] = item
        pendingUploads.insert(item.id)
        persist()
        Task { await pushItems() }
    }

    func setAddyPrice(_ id: String, _ cents: Int) {
        guard var item = items[id] else { return }
        item.priceCents = cents
        item.updatedAt = Date()
        items[id] = item
        pendingUploads.insert(id)
        persist()
        Task { await pushItems() }
    }

    // MARK: Mom's changes

    func setStage(_ id: String, _ s: Stage, soldCents: Int? = nil) {
        var e = ledger.statuses[id] ?? StatusEntry(stage: .ready, updatedAt: Date())
        e.stage = s
        e.soldCents = s == .sold ? soldCents : nil
        e.soldAt = s == .sold ? Date() : nil
        e.updatedAt = Date()
        ledger.statuses[id] = e
        ledgerDirty = true
        persist()
        Task { await pushLedger() }
    }

    func setMomPrice(_ id: String, _ cents: Int) {
        var e = ledger.statuses[id] ?? StatusEntry(stage: stage(id), updatedAt: Date())
        e.priceCents = cents
        e.updatedAt = Date()
        ledger.statuses[id] = e
        ledgerDirty = true
        persist()
        Task { await pushLedger() }
    }

    // MARK: Sync

    func refresh() async {
        guard let code, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let recs = try await cloud.fetch(["addy-\(code)", "mom-\(code)"])
            if let s = recs["addy-\(code)"]?["json"] as? String,
               let idx = try? sharedDecoder.decode([String: Double].self, from: Data(s.utf8)) {
                for (id, t) in idx where (addyIndex[id] ?? 0) < t { addyIndex[id] = t }
            }
            if let s = recs["mom-\(code)"]?["json"] as? String,
               let remote = try? sharedDecoder.decode(Ledger.self, from: Data(s.utf8)) {
                ledger.merge(remote)
                // If this device has newer entries than the server, send them.
                if ledger.statuses.contains(where: { id, e in (remote.statuses[id]?.updatedAt ?? .distantPast) < e.updatedAt }) {
                    ledgerDirty = true
                }
            }
            // Fetch items that are new or changed (never overwrite Addy's own unsent edits).
            let wanted = addyIndex.filter { id, t in
                !pendingUploads.contains(id) && (items[id].map { $0.updatedAt.timeIntervalSince1970 < t - 0.001 } ?? true)
            }.map(\.key)
            if !wanted.isEmpty {
                let fetched = try await cloud.fetch(wanted)
                for (id, rec) in fetched {
                    guard let s = rec["json"] as? String,
                          let item = try? sharedDecoder.decode(Item.self, from: Data(s.utf8)) else { continue }
                    for n in 0..<CloudSync.maxPhotos {
                        let dest = photoURL(id, n)
                        try? FileManager.default.removeItem(at: dest)
                        if let src = (rec["photo\(n)"] as? CKAsset)?.fileURL {
                            try? FileManager.default.copyItem(at: src, to: dest)
                        }
                    }
                    dropCachedImages(id)
                    items[id] = item
                }
            }
            lastSync = Date()
            syncProblem = nil
            persist()
        } catch {
            syncProblem = CloudSync.friendly(error)
        }
        // Whatever this device changed gets sent, whichever mode it's in now.
        if !pendingUploads.isEmpty { await pushItems() }
        if ledgerDirty { await pushLedger() }
    }

    private func pushItems() async {
        guard let code, !pushingItems else { return }
        pushingItems = true
        defer { pushingItems = false }
        do {
            for id in pendingUploads.sorted() {
                guard let item = items[id] else { pendingUploads.remove(id); continue }
                let json = String(decoding: try sharedEncoder.encode(item), as: UTF8.self)
                try await cloud.saveItem(id: id, json: json, photos: photoURLs(item))
                addyIndex[id] = max(addyIndex[id] ?? 0, item.updatedAt.timeIntervalSince1970)
                // Publish the index after each item so Mom sees items one by one.
                try await saveAddyIndex(code)
                if items[id]?.updatedAt == item.updatedAt { pendingUploads.remove(id) }
                persist()
            }
            syncProblem = nil
            lastSync = Date()
        } catch {
            syncProblem = CloudSync.friendly(error)
        }
    }

    /// Re-reads the server copy and merges before saving, and retries if another device saved in between,
    /// so no device (or reinstall) ever wipes items another one added.
    private func saveAddyIndex(_ code: String) async throws {
        let name = "addy-\(code)"
        for attempt in 0..<5 {
            let existing = try await cloud.record(name)
            if let s = existing?["json"] as? String,
               let remote = try? sharedDecoder.decode([String: Double].self, from: Data(s.utf8)) {
                for (id, t) in remote where (addyIndex[id] ?? 0) < t { addyIndex[id] = t }
            }
            let rec = existing ?? cloud.newRecord(type: CloudSync.addyType, name: name)
            rec["json"] = String(decoding: try sharedEncoder.encode(addyIndex), as: UTF8.self)
            do {
                try await cloud.saveIfUnchanged(rec)
                return
            } catch let e where CloudSync.isConflict(e) && attempt < 4 {
                continue
            }
        }
    }

    private func pushLedger() async {
        guard let code, !pushingLedger else { return }
        pushingLedger = true
        defer { pushingLedger = false }
        let name = "mom-\(code)"
        do {
            for attempt in 0..<5 {
                let existing = try await cloud.record(name)
                if let s = existing?["json"] as? String,
                   let remote = try? sharedDecoder.decode(Ledger.self, from: Data(s.utf8)) {
                    ledger.merge(remote)
                }
                let rec = existing ?? cloud.newRecord(type: CloudSync.momType, name: name)
                rec["json"] = String(decoding: try sharedEncoder.encode(ledger), as: UTF8.self)
                do {
                    try await cloud.saveIfUnchanged(rec)
                    break
                } catch let e where CloudSync.isConflict(e) && attempt < 4 {
                    continue
                }
            }
            ledgerDirty = false
            syncProblem = nil
            lastSync = Date()
            persist()
        } catch {
            ledgerDirty = true
            syncProblem = CloudSync.friendly(error)
        }
    }

    // MARK: Local cache

    private struct Snapshot: Codable {
        var items: [String: Item]
        var addyIndex: [String: Double]
        var ledger: Ledger
        var pendingUploads: Set<String>
        var ledgerDirty: Bool
    }
    private var stateURL: URL { Self.supportDir.appendingPathComponent("state.json") }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? sharedDecoder.decode(Snapshot.self, from: data) else { return }
        items = s.items; addyIndex = s.addyIndex; ledger = s.ledger
        pendingUploads = s.pendingUploads; ledgerDirty = s.ledgerDirty
    }

    private func persist() {
        let s = Snapshot(items: items, addyIndex: addyIndex, ledger: ledger, pendingUploads: pendingUploads, ledgerDirty: ledgerDirty)
        if let data = try? sharedEncoder.encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }
}
