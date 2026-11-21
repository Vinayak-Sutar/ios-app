import Foundation

/// The canonical identity of a collection name, used to spot duplicates
/// before any embedding comparison happens.
///
/// Letting a model create folders freely is easy. Doing it without ending up
/// with `Gaming`, `Games`, `Video Games`, `Gaming Stuff` and `PC Gaming` —
/// five folders, one subject — is the actual engineering problem, and it is
/// the hardest thing in the app this one is ported from.
///
/// These checks are the cheap half of the answer: pure string work, no
/// vectors, no model. Most duplicates never reach a similarity comparison at
/// all, which is the point — the expensive check should only see the cases the
/// cheap ones could not settle.
public enum NormKey {

    /// Words that carry no topical meaning in a folder name, so that
    /// "Gaming Stuff" and "Gaming" reduce to the same thing.
    static let stopwords: Set<String> = [
        "stuff", "notes", "note", "misc", "miscellaneous", "general", "other",
        "others", "various", "my", "the", "a", "an", "and", "of", "for",
        "related", "things", "thing", "list", "lists", "links", "link",
        "info", "information", "random", "assorted", "collection", "folder"
    ]

    /// Longest first, so "ational" wins over "al".
    ///
    /// Deliberately cruder than Porter: being *consistent* between variants
    /// matters far more here than being linguistically right. A stemmer that
    /// is wrong the same way every time still collapses duplicates; one that
    /// is subtly right does not necessarily.
    static let suffixes = [
        "ational", "ization", "iveness", "fulness", "ousness", "ements", "ities",
        "ement", "ings", "edly", "ies", "ing", "ers", "est", "ment", "ity",
        "er", "es", "ed", "ly", "s"
    ]

    static func stem(_ word: String) -> String {
        var out = word
        for suffix in suffixes where out.hasSuffix(suffix) && out.count - suffix.count >= 3 {
            out = String(out.dropLast(suffix.count))
            break
        }
        if out.count > 3, out.hasSuffix("e") { out = String(out.dropLast()) }
        if out.count > 3 {
            let last = out[out.index(before: out.endIndex)]
            let previous = out[out.index(out.endIndex, offsetBy: -2)]
            if last == previous { out = String(out.dropLast()) }
        }
        return out
    }

    /// Sorted, so "AI Notes" and "Notes AI" are the same key.
    public static func key(_ name: String) -> String {
        // Slug.tokens, not slugify: slugify substitutes "untitled" for an
        // empty result, which would then be stemmed to "untitl" and become a
        // real key rather than the empty one it should be.
        let words = Slug.tokens(name)
        var stems = Set<String>()
        for word in words where !stopwords.contains(word) {
            let stemmed = stem(word)
            if !stemmed.isEmpty { stems.insert(stemmed) }
        }
        let joined = stems.sorted().joined(separator: " ")
        return joined.isEmpty ? "untitled" : joined
    }

    /// Jaccard over key tokens, where a token that is a prefix of another
    /// counts as a match — so `dev` lines up with `develop`, and `tech` with
    /// `technology`.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = Set(a.components(separatedBy: " ").filter { !$0.isEmpty })
        let right = Set(b.components(separatedBy: " ").filter { !$0.isEmpty })
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        let shared = left.filter { token in matches(token, in: right) }.count
        let union = left.count + right.count - shared
        return union > 0 ? Double(shared) / Double(union) : 0
    }

    static func matches(_ token: String, in others: Set<String>) -> Bool {
        others.contains { other in
            if token == other { return true }
            let shorter = min(token.count, other.count)
            guard shorter >= 3 else { return false }
            return token.hasPrefix(other) || other.hasPrefix(token)
        }
    }

    /// True when every token of `inner` appears in `outer`, and `outer` says
    /// more besides.
    ///
    /// "Gaming Hardware" contains "Gaming". That is the shape of a
    /// **subtopic**, not a duplicate — so the right answer is to nest it
    /// under the containing collection, never to merge it away or let it
    /// become a rival top-level folder. Containment meaning nesting rather
    /// than merging is the single rule that keeps a taxonomy from flattening.
    public static func contains(outer: String, inner: String) -> Bool {
        let outerTokens = Set(outer.components(separatedBy: " ").filter { !$0.isEmpty })
        let innerTokens = Set(inner.components(separatedBy: " ").filter { !$0.isEmpty })
        guard !innerTokens.isEmpty, outerTokens.count > innerTokens.count else { return false }
        return innerTokens.allSatisfy { matches($0, in: outerTokens) }
    }
}
