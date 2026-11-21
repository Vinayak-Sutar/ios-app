import Foundation

/// Tidy-up suggestions the user has waved away.
///
/// In memory and for this session only, deliberately. The proposals are
/// derived from the vault every time it is asked, so a dismissal that
/// outlived the thing it was about would silently suppress a *different*
/// suggestion that happened to get the same id — and the user would never
/// find out why the app stopped noticing something.
actor DismissedProposals {
    private var ids: Set<String> = []

    func insert(_ id: String) {
        ids.insert(id)
    }

    /// A snapshot, so callers can filter synchronously rather than awaiting
    /// inside a loop.
    func all() -> Set<String> {
        ids
    }
}
