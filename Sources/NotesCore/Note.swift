import Foundation

/// A note, mirroring `mnemo/vault.py`'s `Note` dataclass field for field so the
/// Markdown this writes can be read back by the Python app unchanged.
///
/// Two time conventions, deliberately different and not interchangeable:
///   - `created` / `updated` are UTC, `"2026-11-19T18:40:33Z"`.
///   - `due` / `remind` are LOCAL wall-clock with no zone,
///     `"2026-11-15T18:00:00"`, because a reminder set for 6pm means 6pm
///     wherever you are.
public struct Note: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    public var kind: String
    public var status: String

    /// Collection paths. `topics[0]` is the primary one and decides the folder.
    /// Empty means unfiled, which on disk means `Inbox/`.
    public var topics: [String]
    public var entities: [String]
    public var tags: [String]

    public var source: String?
    public var media: String?

    /// The deadline. Separate from `remind` so snoozing moves the reminder
    /// without moving the deadline.
    public var due: String?
    public var remind: String?
    /// Frontmatter key is `repeat`, which is a Swift keyword.
    public var repeatRule: String?
    public var checkin: String?
    public var quietUntil: String?
    public var parent: String?
    public var order: Double?

    public var created: String
    public var updated: String

    public init(
        id: String = ULID.generate(),
        title: String = "",
        body: String = "",
        kind: String = "note",
        status: String = "open",
        topics: [String] = [],
        entities: [String] = [],
        tags: [String] = [],
        source: String? = nil,
        media: String? = nil,
        due: String? = nil,
        remind: String? = nil,
        repeatRule: String? = nil,
        checkin: String? = nil,
        quietUntil: String? = nil,
        parent: String? = nil,
        order: Double? = nil,
        created: String = Timestamp.utcNow(),
        updated: String = Timestamp.utcNow()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.status = status
        self.topics = topics
        self.entities = entities
        self.tags = tags
        self.source = source
        self.media = media
        self.due = due
        self.remind = remind
        self.repeatRule = repeatRule
        self.checkin = checkin
        self.quietUntil = quietUntil
        self.parent = parent
        self.order = order
        self.created = created
        self.updated = updated
    }

    /// The primary collection path, or nil when the note is unfiled.
    public var primaryTopic: String? {
        topics.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What gets embedded. Matches the Python side's `f"{title}\n{body}"`.
    public var embeddingText: String {
        title.isEmpty ? body : "\(title)\n\(body)"
    }
}

public enum Timestamp {
    /// UTC, second precision, trailing `Z` — the form `created`/`updated` use.
    public static func utcNow(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// Local wall-clock, no zone — the form `due`/`remind` use.
    public static func localNow(_ date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}
