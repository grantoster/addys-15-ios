import Foundation
import Security
import UIKit

/// The Anthropic API key: one typed into Settings on this device (kept in the Keychain) wins,
/// otherwise the one built into the app from the repo's ANTHROPIC_API_KEY secret, if any.
enum KeyStore {
    private static let service = "addys15"
    private static let account = "anthropic-api-key"

    static var effective: String? { saved ?? built }
    static var built: String? {
        let k = BuildSecrets.anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }
    static var saved: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    static func save(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct Identified: Decodable {
    var kind: String?
    var brand: String?
    var size: String?
    var color: String?
    var itemName: String?
    var gender: String?
    var pieces: Int?
    var details: [String]?
}

struct ListingResult {
    var title: String
    var description: String
    var comps: [Comp]
}

enum ClaudeError: LocalizedError {
    case noKey, http(Int, String), badReply, offline
    var errorDescription: String? {
        switch self {
        case .noKey: return "Ask a grown-up to add the Claude key in Settings."
        case .offline: return "Can't reach the internet. Check the Wi-Fi and try again."
        case .http(401, _): return "The Claude key isn't working. Ask a grown-up to check it in Settings."
        case .http(429, _), .http(529, _): return "The listing helper is busy. Wait a minute and try again."
        case .http(let c, let m): return "The listing helper had a problem (\(c)). \(m)"
        case .badReply: return "The listing helper got mixed up. Try again."
        }
    }
}

struct Claude {
    /// Writes the listing and looks up prices (up to 5 web searches).
    static let model = "claude-sonnet-5-5"
    /// Reads the photos (brand, type, size from the tag): the cheaper model is plenty here.
    static let photoModel = "claude-haiku-5-5"
    let key: String

    init(key: String) { self.key = key }
    init() throws {
        guard let k = KeyStore.effective else { throw ClaudeError.noKey }
        key = k
    }

    // MARK: Step 1: what is it?

    func identify(images: [UIImage]) async throws -> Identified {
        let prompt = """
        These photos show one kids' clothing item or pair of shoes (or a small bundle) that a family is selling. \
        Photo 1 is the front, photo 2 the back, and photo 3 (if there is one) the tag.

        Reply with only a JSON object, no other text:
        {"kind": one of "shirt","pants","dress","hoodie","jacket","shoes","pajamas","set","bundle","other",
         "brand": the brand exactly as printed on the tag or logo, or null if you can't read one,
         "size": the size as printed on the tag in US kids' notation (like "5T", "18M", "6X", "10", "12C", "2Y"), or null if you can't read it,
         "gender": "girls", "boys", "unisex" or null,
         "color": the main color or colors, a few words,
         "itemName": a plain 2 to 5 word name like "pink fleece hoodie" (no brand, no size),
         "pieces": how many separate pieces are shown (1 for a single item; a pair of shoes is 1),
         "details": up to 5 short features you can clearly see, like "front pocket" or "light-up soles"}

        Never guess a brand or size you can't actually read; use null instead. "set" means a matching outfit sold together.
        """
        var unused = Set<String>()
        let reply = try await send(content: imageParts(images, maxSide: 1024) + [["type": "text", "text": prompt]],
                                   maxTokens: 800, tools: nil, searchedURLs: &unused, model: Self.photoModel)
        guard let json = Self.jsonObject(in: reply) else { throw ClaudeError.badReply }
        return try JSONDecoder().decode(Identified.self, from: json)
    }

    // MARK: Step 2: write the listing and look up prices

    func listing(images: [UIImage], facts: String) async throws -> ListingResult {
        let prompt = """
        A 9-year-old girl is selling her outgrown kids' clothes on Facebook Marketplace with her mom. \
        Write the listing and look up what similar items sell for.

        Facts from the family (these are correct; trust them over the photos):
        \(facts)

        1. "title": at most 70 characters. Brand first if known, then the item, then size, like \
        "Carter's Pink Fleece Hoodie, Girls 5T". No emojis, no ALL CAPS words.
        2. "description": 2 to 4 short sentences in a warm, plain voice, like a parent other parents trust. \
        Say the brand, size and condition honestly, mention the best features you can actually see in the photos \
        (fabric, details, what makes it nice), and state any flaw plainly. Make it appealing without hype: \
        no exclamation points, no words like "amazing" or "must-have", no emojis. Don't mention smoke, pets, \
        pickup, shipping or price; those are added separately. Don't claim anything you can't see or weren't told.
        3. "comps": use web search to find what the same or a very similar item sells for: same brand (or a \
        comparable brand if none), same kind of item, kids' sizes near this one, similar condition. Prefer sold \
        or used listings on eBay, Poshmark, Mercari, ThredUp or Kidizen; don't use Facebook. List only prices you \
        actually saw in the search results, each with the site and the page's URL, up to 8. If you find fewer than \
        3 good matches, list only what you found. Never make up a price.

        Reply with only a JSON object, no other text:
        {"title": "...", "description": "...", "comps": [{"title": "...", "price": 12.50, "source": "eBay (sold)", "url": "https://..."}]}
        """
        let tools: [[String: Any]] = [["type": "web_search_20260318", "name": "web_search", "max_uses": 5]]
        var seen = Set<String>()
        let reply = try await send(content: imageParts(images, maxSide: 1024) + [["type": "text", "text": prompt]],
                                   maxTokens: 3000, tools: tools, searchedURLs: &seen)
        guard let data = Self.jsonObject(in: reply),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = obj["title"] as? String, let desc = obj["description"] as? String else { throw ClaudeError.badReply }
        let comps: [Comp] = (obj["comps"] as? [[String: Any]] ?? []).compactMap { c in
            let price: Double? = (c["price"] as? Double) ?? (c["price"] as? Int).map { Double($0) }
                ?? (c["price"] as? String).flatMap { Money.parse($0) }.map { Double($0) / 100 }
            guard let p = price, p > 0 else { return nil }
            // Only prices from pages the search actually returned; anything else is dropped.
            guard let u = c["url"] as? String, seen.contains(Self.normalize(u)) else { return nil }
            return Comp(title: c["title"] as? String ?? "", priceCents: Money.cents(p),
                        source: c["source"] as? String ?? "", url: c["url"] as? String ?? "")
        }
        return ListingResult(title: String(title.prefix(99)).trimmingCharacters(in: .whitespacesAndNewlines),
                             description: desc.trimmingCharacters(in: .whitespacesAndNewlines), comps: comps)
    }

    // MARK: Plumbing

    private func imageParts(_ images: [UIImage], maxSide: CGFloat) -> [[String: Any]] {
        images.compactMap { img in
            guard let d = img.resized(maxSide: maxSide).jpegData(compressionQuality: 0.75) else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": d.base64EncodedString()]]
        }
    }

    /// Sends one user turn and returns the final reply's text, continuing if the server pauses mid-search.
    private func send(content: [[String: Any]], maxTokens: Int, tools: [[String: Any]]?,
                      searchedURLs: inout Set<String>, model: String = Claude.model) async throws -> String {
        var messages: [[String: Any]] = [["role": "user", "content": content]]
        for _ in 0..<4 {
            var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": messages]
            if let tools { body["tools"] = tools }
            let reply = try await post(body)
            let blocks = reply["content"] as? [[String: Any]] ?? []
            for b in blocks where b["type"] as? String == "web_search_tool_result" {
                for r in b["content"] as? [[String: Any]] ?? [] {
                    if let u = r["url"] as? String { searchedURLs.insert(Self.normalize(u)) }
                }
            }
            if reply["stop_reason"] as? String == "pause_turn" {
                messages.append(["role": "assistant", "content": blocks])
                continue
            }
            return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        throw ClaudeError.badReply
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw ClaudeError.offline }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200 else {
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? ""
            throw ClaudeError.http(code, msg)
        }
        return obj
    }

    /// Host + path, lowercased, without "www." or a trailing slash, for matching URLs.
    static func normalize(_ s: String) -> String {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespaces)), let host = c.host?.lowercased() else {
            return s.lowercased()
        }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var p = c.path.lowercased()
        while p.hasSuffix("/") { p.removeLast() }
        return h + p + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    /// The JSON object in a reply (from the first "{" to the last "}").
    static func jsonObject(in text: String) -> Data? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return nil }
        return Data(text[a...b].utf8)
    }
}

extension UIImage {
    /// Upright copy no larger than maxSide on its long side.
    func resized(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        let scale = longest > 0 ? min(1, maxSide / longest) : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
