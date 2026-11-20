import Foundation

/// To-do lines inside a note's Markdown, ported from `mnemo/checklist.py`.
///
/// Items live in the note body as ordinary Markdown, Obsidian-Tasks style:
///
///     ## Maths 📅 2026-11-10
///     - [ ] Probability ⏰ 2026-11-05 18:00
///     - [ ] Optics 🔁 every week
///     - [x] Calculus ✅ 2026-10-27
///
/// Keeping them in the text rather than in a database is what lets the same
/// note open correctly in Obsidian, and what lets the index stay disposable.
public enum Checklist {

    public struct Item: Sendable, Equatable {
        /// 0-based index of the line in the body.
        public var line: Int
        public var text: String
        public var done: Bool
        /// 📅 — the day it is due.
        public var due: String?
        /// ⏰ — when to speak up.
        public var remind: String?
        /// 🔁 — how it repeats.
        public var repeatRule: String?
        /// ✅ — the day it was ticked.
        public var completed: String?

        public init(
            line: Int,
            text: String,
            done: Bool,
            due: String? = nil,
            remind: String? = nil,
            repeatRule: String? = nil,
            completed: String? = nil
        ) {
            self.line = line
            self.text = text
            self.done = done
            self.due = due
            self.remind = remind
            self.repeatRule = repeatRule
            self.completed = completed
        }
    }

    static let dueMark = "\u{1F4C5}"        // 📅
    static let remindMark = "\u{23F0}"      // ⏰
    static let repeatMark = "\u{1F501}"     // 🔁
    static let doneMark = "\u{2705}"        // ✅

    /// Emoji in text often carry a variation selector, and a note edited on a
    /// phone keyboard will have them where one typed on a laptop may not.
    /// Stripping it is the difference between parsing a user's note and
    /// silently ignoring it.
    ///
    /// It has to be stripped at the **scalar** level. `⏰` followed by U+FE0F
    /// is a single Swift `Character`, so filtering characters never removes
    /// it — the comparison just quietly fails and the mark is dropped.
    static let variationSelector: Unicode.Scalar = "\u{FE0F}"

    static func stripVariationSelectors(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != variationSelector }))
    }

    // MARK: - Reading

    public static func items(in body: String) -> [Item] {
        var out: [Item] = []
        var inFence = false

        for (index, raw) in body.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // A checkbox inside a code fence is an example, not a task.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            guard let box = checkbox(line) else { continue }
            out.append(parse(line: index, after: box.rest, done: box.done))
        }
        return out
    }

    /// `- [ ] text` / `- [x] text`, also accepting `*` and `+` bullets.
    static func checkbox(_ line: String) -> (done: Bool, rest: String)? {
        var text = line
        guard let bullet = text.first, "-*+".contains(bullet) else { return nil }
        text.removeFirst()
        guard text.hasPrefix(" ") else { return nil }
        text = String(text.drop(while: { $0 == " " }))

        guard text.hasPrefix("["), text.count >= 3 else { return nil }
        let mark = text[text.index(text.startIndex, offsetBy: 1)]
        guard text[text.index(text.startIndex, offsetBy: 2)] == "]" else { return nil }
        guard mark == " " || mark == "x" || mark == "X" else { return nil }

        let rest = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return (done: mark != " ", rest: rest)
    }

    static func parse(line: Int, after rest: String, done: Bool) -> Item {
        var item = Item(line: line, text: rest, done: done)
        var words: [String] = []
        var current: Character?
        var buffer: [String] = []

        func flush() {
            guard let mark = current else { return }
            let value = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            switch mark {
            case Character(dueMark): item.due = value
            case Character(remindMark): item.remind = value
            case Character(repeatMark): item.repeatRule = value
            case Character(doneMark): item.completed = value
            default: break
            }
            buffer = []
        }

        for word in rest.components(separatedBy: " ") {
            let cleaned = stripVariationSelectors(word)
            if cleaned.count == 1, let first = cleaned.first,
               [dueMark, remindMark, repeatMark, doneMark].contains(String(first)) {
                flush()
                current = first
                continue
            }
            if current == nil {
                words.append(word)
            } else {
                buffer.append(cleaned)
            }
        }
        flush()

        item.text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return item
    }

    // MARK: - Writing

    /// Tick or untick one item, found by line but verified by text.
    ///
    /// The line number comes from a page that may be a moment out of date, so
    /// it is a hint: if the text at that line does not match, the item is
    /// looked up by text instead. Toggling the wrong line silently is the
    /// failure worth avoiding here.
    public static func setDone(
        _ body: String,
        line: Int,
        text: String,
        done: Bool,
        today: String
    ) -> String? {
        var lines = body.components(separatedBy: "\n")
        var target: Int?

        if line >= 0, line < lines.count,
           let box = checkbox(lines[line].trimmingCharacters(in: .whitespaces)),
           parse(line: line, after: box.rest, done: box.done).text == text {
            target = line
        } else {
            for item in items(in: body) where item.text == text {
                target = item.line
                break
            }
        }

        guard let index = target else { return nil }
        let original = lines[index]
        let indent = String(original.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        guard let box = checkbox(trimmed) else { return nil }

        var item = parse(line: index, after: box.rest, done: box.done)
        item.done = done
        // Record or clear the completion day, keeping every other mark. A
        // rewrite that drops ⏰ or 🔁 would quietly cancel a repeat.
        item.completed = done ? today : nil

        lines[index] = indent + render(item)
        return lines.joined(separator: "\n")
    }

    public static func render(_ item: Item) -> String {
        var out = "- [\(item.done ? "x" : " ")] \(item.text)"
        if let due = item.due, !due.isEmpty { out += " \(dueMark) \(due)" }
        if let remind = item.remind, !remind.isEmpty { out += " \(remindMark) \(remind)" }
        if let rule = item.repeatRule, !rule.isEmpty { out += " \(repeatMark) \(rule)" }
        if let completed = item.completed, !completed.isEmpty { out += " \(doneMark) \(completed)" }
        return out
    }

    /// `[done, total]`, or nil when the note has no checkboxes at all — which
    /// is how a plain note is told apart from an empty list.
    public static func progress(in body: String) -> [Int]? {
        let all = items(in: body)
        guard !all.isEmpty else { return nil }
        return [all.filter(\.done).count, all.count]
    }
}
