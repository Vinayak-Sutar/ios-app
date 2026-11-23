import Foundation

/// The collection tree the sidebar draws.
///
/// Collections nest: the gate puts "Video Games" under "Gaming" rather than
/// beside it, which is the whole point of having a gate. The bridge used to
/// send a flat list anyway, so a nested collection appeared as a second
/// top-level row — "Gaming" and "Video Games", unrelated — and the parent's
/// badge counted only the notes directly inside it. The map drew the parent
/// link correctly all along, so the two screens disagreed about the shape of
/// the same vault.
///
/// Pure, and tested on Windows, because the error that matters here is
/// arithmetic: a subtree total that double-counts or drops a branch is the
/// kind of thing you cannot see by looking at it.
public enum TopicTree {

    public struct Node: Sendable, Equatable {
        /// The last path component, which is what a row is labelled with.
        public var name: String
        /// The full path, which is what a tap on the row opens.
        public var path: String
        /// Notes filed directly here.
        public var own: Int
        /// Notes here and anywhere below. What the badge shows.
        public var total: Int
        public var children: [Node]

        public init(name: String, path: String, own: Int, total: Int, children: [Node] = []) {
            self.name = name
            self.path = path
            self.own = own
            self.total = total
            self.children = children
        }
    }

    /// Build the tree from each collection's own note count.
    ///
    /// Alphabetical at every level, the order the flat list already arrived
    /// in, so this changes the shape of the sidebar and not its sorting.
    public static func build(counts: [String: Int]) -> [Node] {
        var root = Branch()
        for (path, count) in counts {
            let components = path
                .components(separatedBy: "/")
                .filter { !$0.isEmpty }
            guard !components.isEmpty else { continue }
            root.insert(components[...], count: count)
        }
        return root.nodes(at: "")
    }

    /// A recursive struct rather than a class: nothing escapes, and a
    /// dictionary of itself is the indirection Swift needs.
    private struct Branch {
        var own = 0
        var children: [String: Branch] = [:]

        mutating func insert(_ components: ArraySlice<String>, count: Int) {
            guard let first = components.first else {
                own += count
                return
            }
            // A collection whose parent holds no notes of its own still needs
            // the parent to exist, or the row has nothing to hang from.
            var child = children[first] ?? Branch()
            child.insert(components.dropFirst(), count: count)
            children[first] = child
        }

        func nodes(at path: String) -> [Node] {
            children
                .sorted { $0.key < $1.key }
                .map { name, branch in
                    let full = path.isEmpty ? name : path + "/" + name
                    let kids = branch.nodes(at: full)
                    return Node(
                        name: name,
                        path: full,
                        own: branch.own,
                        total: branch.own + kids.reduce(0) { $0 + $1.total },
                        children: kids
                    )
                }
        }
    }
}
