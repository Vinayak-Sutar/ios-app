import Foundation
import NotesCore
import UserNotifications

/// Reminders, and the one thing this app can do that the web version cannot.
///
/// The Windows app's own roadmap has "reminders with the page closed" still
/// open, and on a phone it is blocked on having an https address for a service
/// worker. Here it is just `UNUserNotificationCenter`, and notably it needs
/// **no entitlement** — local notifications are free where push would have
/// required the paid developer account this project does not have.
///
/// Two ideas carried over from `mnemo/reminders.py`:
///
/// - **Fire-once keys.** Every alert has a key like `task:<id>:<time>`, and a
///   fired key is remembered. Without that, reopening the app re-fires
///   everything that was ever due.
/// - **Wall-clock times.** `remind` has no timezone, because a reminder set
///   for 6pm means 6pm wherever you are. The conversion to an absolute `Date`
///   happens here and nowhere else.
@MainActor
final class Reminders {

    private let vault: Vault
    private var fired: Set<String> = []
    private let firedURL: URL

    init(vault: Vault) {
        self.vault = vault
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.firedURL = support.appendingPathComponent("fired.json")
        loadFired()
    }

    // MARK: - Permission

    private(set) var authorization: String = "not asked"

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorization = granted ? "granted" : "denied"
        } catch {
            authorization = "failed: \(error.localizedDescription)"
        }
        Log.routes.notice("notification authorization: \(self.authorization, privacy: .public)")
    }

    // MARK: - Scheduling

    /// Schedule an OS notification for a note's reminder time.
    ///
    /// Scheduled rather than polled: a pre-registered `UNNotificationRequest`
    /// fires whether or not the app is running, which is the entire point. The
    /// in-app alert cards are a second, separate path for when the app happens
    /// to be open.
    func schedule(_ note: Note) async {
        guard let remind = note.remind, let components = Self.components(from: remind) else { return }
        let key = Self.taskKey(noteID: note.id, when: remind)

        let content = UNMutableNotificationContent()
        content.title = note.title.isEmpty ? "Reminder" : note.title
        if let topic = note.primaryTopic { content.subtitle = topic }
        content.body = String(API.NoteBrief.snippet(from: note.body, limit: 120))
        content.sound = .default
        content.userInfo = ["noteId": note.id, "key": key]

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: key, content: content, trigger: trigger)

        do {
            // Same identifier replaces rather than duplicates, so rescheduling
            // after an edit is safe.
            try await UNUserNotificationCenter.current().add(request)
            Log.routes.notice("scheduled \(key, privacy: .public)")
        } catch {
            Log.routes.error("could not schedule \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancel(noteID: String) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { ($0.content.userInfo["noteId"] as? String) == noteID }
            .map(\.identifier)
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Re-register everything on launch. Pending requests survive a relaunch,
    /// but not a reinstall — and with a 7-day sideload that is every week.
    func rescheduleAll() async {
        for entry in vault.notes(status: "open") where entry.note.remind != nil {
            await schedule(entry.note)
        }
    }

    func pendingCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests().count
    }

    // MARK: - In-app alerts

    /// What `/api/due` answers with: anything due that has not fired yet.
    ///
    /// Shaped exactly as `app.html`'s `showAlert` reads it — `type`, `key`,
    /// `when`, `title`, `topic`, `noteId` — which was taken from the page, not
    /// guessed.
    func dueNow(at now: Date = Date()) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let today = Timestamp.localNow(now)
        guard let nowDate = PlainDate.parse(today) else { return [] }

        for entry in vault.notes(status: "open") {
            // The note's own reminder.
            if let remind = entry.note.remind,
               let date = PlainDate.parse(remind), date <= nowDate {
                let key = Self.taskKey(noteID: entry.note.id, when: remind)
                if !fired.contains(key), !quiet(entry.note, at: nowDate) {
                    out.append([
                        "type": "task",
                        "key": key,
                        "when": remind,
                        "title": entry.note.title.isEmpty ? "Untitled" : entry.note.title,
                        "topic": entry.note.primaryTopic as Any? ?? NSNull(),
                        "noteId": entry.note.id
                    ])
                }
            }

            // Reminders on individual checklist items (their ⏰ mark).
            for item in Checklist.items(in: entry.note.body) where !item.done {
                guard let remind = item.remind,
                      let date = PlainDate.parse(remind), date <= nowDate else { continue }
                let key = "item:\(entry.note.id):\(remind):\(item.text)"
                guard !fired.contains(key), !quiet(entry.note, at: nowDate) else { continue }
                out.append([
                    "type": "item",
                    "key": key,
                    "when": remind,
                    "text": item.text,
                    "line": item.line,
                    "listTitle": entry.note.title.isEmpty ? "Untitled" : entry.note.title,
                    "topic": entry.note.primaryTopic as Any? ?? NSNull(),
                    "noteId": entry.note.id
                ])
            }

            // A list with a deadline speaks up the day before, and once after.
            guard let progress = Checklist.progress(in: entry.note.body),
                  let due = entry.note.due,
                  let dueDate = PlainDate.parse(due),
                  !quiet(entry.note, at: nowDate) else { continue }

            let daysLeft = nowDate.days(until: dueDate)
            let finished = progress[0] >= progress[1] && progress[1] > 0
            if finished { continue }

            if daysLeft == 1 || daysLeft == 0 {
                let key = "deadline-soon:\(entry.note.id):\(due)"
                if !fired.contains(key) {
                    out.append(deadlineCard(entry, progress: progress, due: due, key: key, late: false))
                }
            } else if daysLeft < 0 {
                // Once, and then the daily nagging stops.
                let key = "deadline-missed:\(entry.note.id):\(due)"
                if !fired.contains(key) {
                    out.append(deadlineCard(entry, progress: progress, due: due, key: key, late: true))
                }
            }
        }
        return out
    }

    private func deadlineCard(
        _ entry: Vault.Entry, progress: [Int], due: String, key: String, late: Bool
    ) -> [String: Any] {
        [
            "type": "deadline",
            "key": key,
            "when": due,
            "due": due,
            "late": late,
            "done": progress[0],
            "total": progress[1],
            "title": entry.note.title.isEmpty ? "Untitled" : entry.note.title,
            "topic": entry.note.primaryTopic as Any? ?? NSNull(),
            "noteId": entry.note.id
        ]
    }

    /// "Don't remind me about this until Monday."
    private func quiet(_ note: Note, at now: PlainDate) -> Bool {
        guard let until = note.quietUntil, let date = PlainDate.parse(until) else { return false }
        return now < date
    }

    /// Move repeating things on rather than finishing them.
    ///
    /// Ticking a repeating reminder should set the next occurrence, not mark
    /// it done — otherwise "water the plants every Monday" survives exactly
    /// one Monday.
    @discardableResult
    func advanceRepeat(_ note: inout Note, at now: Date = Date()) -> Bool {
        guard let rule = note.repeatRule, Repeats.parse(rule) != nil else { return false }
        let from = note.remind ?? note.due ?? Timestamp.localNow(now)

        if let remind = note.remind {
            note.remind = Repeats.nextStamp(after: Timestamp.localNow(now), rule: rule, anchor: remind)
        }
        if let due = note.due {
            note.due = Repeats.nextStamp(after: Timestamp.localNow(now), rule: rule, anchor: due)
        }
        if note.remind == nil && note.due == nil {
            note.due = Repeats.nextStamp(after: Timestamp.localNow(now), rule: rule, anchor: from)
        }
        return note.remind != nil || note.due != nil
    }

    /// The page posts back the keys it has shown, so nothing fires twice.
    func markFired(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        fired.formUnion(keys)
        saveFired()
    }

    /// On a rebuild, anything already in the past is marked fired rather than
    /// fired now. Otherwise a reinstall greets you with every reminder you
    /// ever set.
    func markPastAsFired(at now: Date = Date()) {
        for entry in vault.entries.values {
            guard let remind = entry.note.remind,
                  let date = Self.date(from: remind),
                  date <= now else { continue }
            fired.insert(Self.taskKey(noteID: entry.note.id, when: remind))
        }
        saveFired()
    }

    // MARK: - Time

    static func taskKey(noteID: String, when: String) -> String {
        "task:\(noteID):\(when)"
    }

    /// `"2026-11-15T18:00:00"` — local wall-clock, no zone — into date
    /// components. Parsed by hand rather than with a formatter: a formatter
    /// configured with the wrong locale or calendar silently shifts the hour,
    /// and a reminder at the wrong time is worse than none.
    static func components(from wallClock: String) -> DateComponents? {
        let parts = wallClock.components(separatedBy: "T")
        guard parts.count == 2 else { return nil }
        let date = parts[0].components(separatedBy: "-")
        let time = parts[1].components(separatedBy: ":")
        guard date.count == 3, time.count >= 2,
              let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              let hour = Int(time[0]), let minute = Int(time[1]),
              (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components
    }

    static func date(from wallClock: String) -> Date? {
        guard let components = components(from: wallClock) else { return nil }
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: - The fired ledger

    private func loadFired() {
        guard let data = try? Data(contentsOf: firedURL),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return }
        fired = Set(keys)
    }

    private func saveFired() {
        // Unbounded growth is not a concern at prototype scale, but a cap
        // keeps the file from becoming a liability if it ever is.
        if fired.count > 5000 { fired = Set(fired.suffix(2000)) }
        guard let data = try? JSONEncoder().encode(Array(fired)) else { return }
        try? data.write(to: firedURL, options: .atomic)
    }
}
