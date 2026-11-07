import Foundation

enum Role: String, Codable { case addy, mom }

enum Kind: String, Codable, CaseIterable, Identifiable {
    case shirt, pants, dress, hoodie, jacket, shoes, pajamas, set, bundle, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shirt: return "Shirt"
        case .pants: return "Pants"
        case .dress: return "Dress"
        case .hoodie: return "Hoodie"
        case .jacket: return "Jacket"
        case .shoes: return "Shoes"
        case .pajamas: return "Pajamas"
        case .set: return "Outfit"
        case .bundle: return "Bundle"
        case .other: return "Other"
        }
    }
}

enum Condition: String, Codable, CaseIterable, Identifiable {
    case newWithTags, neverWorn, gentlyUsed, playedIn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newWithTags: return "New with tags"
        case .neverWorn: return "Never worn"
        case .gentlyUsed: return "Gently used"
        case .playedIn: return "Played in"
        }
    }
    var symbol: String {
        switch self {
        case .newWithTags: return "tag.fill"
        case .neverWorn: return "star.fill"
        case .gentlyUsed: return "hand.thumbsup.fill"
        case .playedIn: return "sun.max.fill"
        }
    }
    /// The matching choice in Facebook Marketplace's Condition menu.
    var facebook: String {
        switch self {
        case .newWithTags: return "New"
        case .neverWorn: return "Used – Like New"
        case .gentlyUsed: return "Used – Good"
        case .playedIn: return "Used – Fair"
        }
    }
}

/// A price seen online for a similar item, with where it was seen.
struct Comp: Codable, Hashable {
    var title: String
    var priceCents: Int
    var source: String
    var url: String
}

struct Item: Codable, Identifiable, Hashable {
    var id: String
    var createdAt: Date
    var updatedAt: Date
    var kind: Kind
    var brand: String
    var size: String
    var color: String
    var itemName: String
    var gender: String?
    var pieces: Int
    var condition: Condition
    var hasFlaws: Bool
    var title: String
    var description: String
    var comps: [Comp]
    /// Median of the online prices found, rounded to the dollar. Nil when fewer than 3 were found.
    var suggestedPriceCents: Int?
    /// The price Addy chose (starts at the suggestion).
    var priceCents: Int?
    var photoCount: Int

    var compRange: (low: Int, high: Int)? {
        let p = comps.map(\.priceCents).filter { $0 > 0 }
        guard p.count >= 3, let lo = p.min(), let hi = p.max() else { return nil }
        return (lo, hi)
    }
}

enum Stage: String, Codable { case ready, listed, sold, removed }

struct StatusEntry: Codable, Hashable {
    var stage: Stage
    var soldCents: Int?
    var priceCents: Int?
    var updatedAt: Date
    var soldAt: Date?
}

/// Mom's side of the shared state: what happened to each item, and any price she changed.
struct Ledger: Codable {
    var statuses: [String: StatusEntry] = [:]

    mutating func merge(_ other: Ledger) {
        for (id, e) in other.statuses where (statuses[id]?.updatedAt ?? .distantPast) < e.updatedAt {
            statuses[id] = e
        }
    }
}

enum Money {
    /// "$10" for whole dollars, "$9.50" otherwise.
    static func price(_ cents: Int) -> String {
        cents % 100 == 0 ? "$\(cents / 100)" : full(cents)
    }
    /// Always with cents: "$12.45".
    static func full(_ cents: Int) -> String {
        String(format: "$%d.%02d", cents / 100, cents % 100)
    }
    /// Addy's 15%, rounded to the cent with halves going up.
    static func share(_ cents: Int) -> Int { (cents * 15 + 50) / 100 }
    /// Nearest whole dollar, halves going up.
    static func roundToDollar(_ cents: Int) -> Int { ((cents + 50) / 100) * 100 }
    static func median(_ xs: [Int]) -> Int {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m] + 1) / 2
    }
    /// Parses "12", "12.5", "$12.50" into cents (halves of a cent go up). Nil if not a positive amount.
    static func parse(_ text: String) -> Int? {
        let t = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let d = Decimal(string: t), d > 0 else { return nil }
        var x = d * 100
        var r = Decimal()
        NSDecimalRound(&r, &x, 0, .plain)
        return NSDecimalNumber(decimal: r).intValue
    }
    static func cents(_ dollars: Double) -> Int { Int((dollars * 100).rounded()) }
}

enum Sizes {
    static let clothes = ["NB", "0-3M", "3-6M", "6-9M", "9-12M", "12M", "18M", "24M", "2T", "3T", "4T", "5T",
                          "4", "5", "6", "6X", "7", "8", "10", "12", "14", "16", "XS", "S", "M", "L", "XL"]
    static let shoes = (1...13).map { "\($0)C" } + (1...7).map { "\($0)Y" }
    static let unknown = "Not sure"

    static func list(for kind: Kind?, including s: String?) -> [String] {
        var l = kind == .shoes ? shoes : clothes
        if let s, s != unknown, !l.contains(s) { l.insert(s, at: 0) }
        return l + [unknown]
    }

    static func normalize(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for (a, b) in [(" MONTHS", "M"), (" MONTH", "M"), ("MONTHS", "M"), (" MOS", "M"), ("MOS", "M"), (" MO", "M"), (" ", "")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        if let m = (clothes + shoes).first(where: { $0.uppercased() == t }) { return m }
        return t.isEmpty ? unknown : t
    }
}

enum Pairing {
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static func newCode() -> String { String((0..<6).map { _ in alphabet.randomElement()! }) }
    /// Codes never use 0, O, 1, I or L, so anything else typed is dropped.
    static func normalize(_ s: String) -> String { String(s.uppercased().filter { alphabet.contains($0) }) }
    static func pretty(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3))-\(code.suffix(3))" : code
    }
}

let sharedEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
let sharedDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
