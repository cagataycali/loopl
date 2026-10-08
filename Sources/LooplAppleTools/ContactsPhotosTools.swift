import Foundation
import Loopl
#if canImport(Contacts)
import Contacts
#endif
#if canImport(Photos)
import Photos
#endif

// `contacts_search` and `photos_recent` (lane TOOLS-EXPAND, 2026-10-06). Both OFF by default, both read-only,
// both ask their permission just in time (`NSContactsUsageDescription`, `NSPhotoLibraryUsageDescription` — limited
// library access is enough for photos: the person picks which pictures loopl may ever see). Seams
// (`ContactsSource`, `PhotosSource`) carry the fixtures for tests, the real-model harness and `--design-fixture`.

// MARK: - contacts_search

public struct ContactCard: Sendable, Hashable, Codable {
    public var name: String
    public var phones: [String]
    public var emails: [String]
    public var organization: String?
    public init(name: String, phones: [String] = [], emails: [String] = [], organization: String? = nil) { self.name = name; self.phones = phones; self.emails = emails; self.organization = organization }
}

public protocol ContactsSource: Sendable {
    func search(name: String, limit: Int) async throws -> [ContactCard]
}

public final class FixtureContactsSource: ContactsSource, @unchecked Sendable {
    public var cards: [ContactCard]
    public private(set) var queries: [String] = []
    public init(_ cards: [ContactCard] = [
        ContactCard(name: "Ali Yılmaz", phones: ["+90 532 000 11 22"], emails: ["ali@example.com"], organization: "Acme"),
        ContactCard(name: "Alice Park", phones: ["+1 (201) 555-0142"], emails: ["alice.park@example.org"]),
        ContactCard(name: "Mum", phones: ["+90 212 555 00 00"]),
    ]) { self.cards = cards }
    public func search(name: String, limit: Int) async throws -> [ContactCard] {
        queries.append(name)
        let q = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return Array(cards.filter { $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(q) }.prefix(limit))
    }
}

public enum ContactsStore {
    nonisolated(unsafe) private static var override: (any ContactsSource)?
    private static let lock = NSLock()
    public static func use(_ s: (any ContactsSource)?) { lock.lock(); override = s; lock.unlock() }
    public static var isFixture: Bool { lock.lock(); defer { lock.unlock() }; return override != nil }
    static var current: any ContactsSource {
        lock.lock(); defer { lock.unlock() }
        if let o = override { return o }
        #if canImport(Contacts)
        return CNContactsSource()
        #else
        return FixtureContactsSource([])
        #endif
    }
}

#if canImport(Contacts)
struct CNContactsSource: ContactsSource {
    func search(name: String, limit: Int) async throws -> [ContactCard] {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited: break
        case .notDetermined:
            guard try await store.requestAccess(for: .contacts) else { throw ToolError("the user did not allow access to Contacts") }
        default: throw ToolError("access to Contacts is off — the user can allow it in Settings › Privacy › Contacts › loopl")
        }
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor,
                                       CNContactEmailAddressesKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor]
        let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
        return found.prefix(limit).map { c in
            ContactCard(name: CNContactFormatter.string(from: c, style: .fullName) ?? "(no name)",
                        phones: c.phoneNumbers.map { $0.value.stringValue }, emails: c.emailAddresses.map { String($0.value) },
                        organization: c.organizationName.isEmpty ? nil : c.organizationName)
        }
    }
}
#endif

public struct ContactsSearchTool: AppleTool {
    public init() {}
    public let name = "contacts_search"
    public let description = "Look up a person in the user's Contacts app by name: phone numbers, email addresses, company. Call it whenever the user asks for someone's phone number, email address or contact details, or wants to call, text or email a person — you do not know their contacts without it (then open_app with tel:/sms:/mailto:)."
    public let parameters: JSONValue = ToolSchema.object([
        "name": ToolSchema.string("The name, or part of it, e.g. Ali"),
        "limit": ToolSchema.number("Maximum matches (default 5)"),
    ], required: ["name"])
    public static let onDeviceCopy = "Looks up names in your contacts when the model asks; nothing is changed. Asks for Contacts access the first time."
    public static var defaultOn: Bool { false }
    public static let maxLimit = 20

    public static func availability() -> ToolAvailability {
        if ContactsStore.isFixture { return .ok }
        #if canImport(Contacts)
        return .ok
        #else
        return .no("Needs Contacts")
        #endif
    }
    public struct Request: Sendable, Hashable { public var name: String; public var limit: Int }
    public static func parse(_ args: [String: JSONValue]) throws -> Request {
        guard let n = (args.string("name") ?? args.string("query") ?? args.string("q"))?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { throw ToolError("need a name to search for") }
        return Request(name: n, limit: max(1, min(maxLimit, args.int("limit") ?? 5)))
    }
    public static func render(_ cards: [ContactCard], query: String) -> String {
        if cards.isEmpty { return "contacts: no one named \"\(query)\"" }
        let lines = cards.map { c -> String in
            var parts = [c.name]
            if let o = c.organization { parts[0] += " (\(o))" }
            if !c.phones.isEmpty { parts.append("phone " + c.phones.joined(separator: ", ")) }
            if !c.emails.isEmpty { parts.append("email " + c.emails.joined(separator: ", ")) }
            return "- " + parts.joined(separator: " · ")
        }
        return "contacts: \(cards.count) match\(cards.count == 1 ? "" : "es") for \"\(query)\"\n" + lines.joined(separator: "\n")
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let r = try Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("contacts_search is not available here: \(a.reason)") }
        return Self.render(try await ContactsStore.current.search(name: r.name, limit: r.limit), query: r.name)
    }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput { ToolOutput(text: try await call(args)) }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}

// MARK: - photos_recent

public struct PhotoItem: Sendable, Hashable {
    public var image: ImageBlock
    public var taken: Date?
    public init(image: ImageBlock, taken: Date?) { self.image = image; self.taken = taken }
}

public protocol PhotosSource: Sendable {
    /// Newest first; `on` restricts to one local day.
    func recent(count: Int, on day: Date?) async throws -> [PhotoItem]
}

public final class FixturePhotosSource: PhotosSource, @unchecked Sendable {
    public var items: [PhotoItem]
    public private(set) var requests: [(Int, Date?)] = []
    /// `now` is the clock this fixture is built against; tests pin it to reach a particular hour.
    public init(_ items: [PhotoItem]? = nil, now: Date = Date()) {
        if let items { self.items = items; return }
        // Three photos, newest first, all inside the SAME LOCAL DAY as `now` — spread across the part
        // of that day which has already happened, so they are never in the future either.
        // They used to be `now - 1h/-2h/-3h`, which made this a different fixture depending on the
        // time of day: before 01:00 all three fell on YESTERDAY, so "photos from today" correctly
        // returned nothing and every test assuming otherwise failed for one hour in every twenty-four.
        let elapsedToday = max(0, now.timeIntervalSince(Calendar.current.startOfDay(for: now)))
        var made: [PhotoItem] = []
        for i in 0..<3 {
            if let cg = ImageCodec.testImage(width: 320, height: 200), let b = try? ImageCodec.jpeg(cg, alt: "fixture photo \(i + 1)") {
                made.append(PhotoItem(image: b, taken: now.addingTimeInterval(-elapsedToday * Double(i + 1) / 4)))
            }
        }
        self.items = made
    }
    public func recent(count: Int, on day: Date?) async throws -> [PhotoItem] {
        requests.append((count, day))
        var list = items
        if let day { list = list.filter { $0.taken.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false } }
        return Array(list.prefix(count))
    }
}

public enum PhotosStore {
    nonisolated(unsafe) private static var override: (any PhotosSource)?
    private static let lock = NSLock()
    public static func use(_ s: (any PhotosSource)?) { lock.lock(); override = s; lock.unlock() }
    public static var isFixture: Bool { lock.lock(); defer { lock.unlock() }; return override != nil }
    static var current: any PhotosSource {
        lock.lock(); defer { lock.unlock() }
        if let o = override { return o }
        #if canImport(Photos) && !os(watchOS)
        return PHPhotosSource()
        #else
        return FixturePhotosSource([])
        #endif
    }
}

#if canImport(Photos) && !os(watchOS)
struct PHPhotosSource: PhotosSource {
    func recent(count: Int, on day: Date?) async throws -> [PhotoItem] {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        switch status {
        case .authorized, .limited: break
        default: throw ToolError("access to Photos is off — the user can allow it (all or selected pictures) in Settings › Privacy › Photos › loopl")
        }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let day {
            let start = Calendar.current.startOfDay(for: day), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
            opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@ AND mediaType == %d", start as NSDate, end as NSDate, PHAssetMediaType.image.rawValue)
        } else {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        opts.fetchLimit = count
        let assets = PHAsset.fetchAssets(with: opts)
        var out: [PhotoItem] = []
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            let data: Data? = await withCheckedContinuation { c in
                let o = PHImageRequestOptions(); o.isNetworkAccessAllowed = true; o.deliveryMode = .highQualityFormat; o.isSynchronous = false
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { d, _, _, _ in c.resume(returning: d) }
            }
            guard let data, let cg = try? ImageCodec.cgImage(ImageBlock(data: data, mime: "image/jpeg")),
                  let block = try? ImageCodec.jpeg(cg, alt: "photo from the library") else { continue }
            out.append(PhotoItem(image: block, taken: asset.creationDate))
        }
        return out
    }
}
#endif

public struct PhotosRecentTool: AppleTool {
    public init() {}
    public let name = "photos_recent"
    public let description = "Get the user's most recent photos (or the photos from one day) as pictures attached to the result, so you can describe them or answer questions about them. Use when the user asks about their latest photo, pictures from a day, or says \"the photo I just took\"."
    public let parameters: JSONValue = ToolSchema.object([
        "count": ToolSchema.number("How many, newest first (default 1, max 4)"),
        "date": ToolSchema.string("Only photos from this day, yyyy-MM-dd (optional)"),
    ])
    public static let onDeviceCopy = "Hands the model your newest photos (or one day's) when it asks. Works with Selected Photos access. Nothing leaves the device."
    public static var defaultOn: Bool { false }
    public static let maxCount = 4

    public static func availability() -> ToolAvailability {
        if PhotosStore.isFixture { return .ok }
        #if canImport(Photos) && !os(watchOS)
        return .ok
        #else
        return .no("Needs the Photos library")
        #endif
    }
    public struct Request: Sendable, Hashable { public var count: Int; public var day: Date? }
    public static func parse(_ args: [String: JSONValue]) throws -> Request {
        let count = max(1, min(maxCount, args.int("count") ?? args.int("limit") ?? 1))
        var day: Date? = nil
        if let d = args.string("date") ?? args.string("day"), !d.isEmpty {
            guard let (parsed, _) = AgendaStore.parseDate(d) else { throw ToolError("date must look like 2026-10-06") }
            day = parsed
        }
        return Request(count: count, day: day)
    }
    public func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let r = try Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("photos_recent is not available here: \(a.reason)") }
        let items = try await PhotosStore.current.recent(count: r.count, on: r.day)
        let scope = r.day.map { " from " + AgendaStore.dayFormatter.string(from: $0) } ?? ""
        if items.isEmpty { return ToolOutput(text: "photos: none\(scope) (the user may have given loopl access to selected photos only)") }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
        let lines = items.enumerated().map { i, p in "- photo \(i + 1): \(p.taken.map { f.string(from: $0) } ?? "date unknown")\(p.image.width.map { ", \($0)×\(p.image.height ?? 0)" } ?? "")" }
        let text = "photos: \(items.count)\(scope), attached to this result (newest first) — describe them or call describe_image\n" + lines.joined(separator: "\n")
        return ToolOutput(text: text, images: items.map(\.image))
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}
