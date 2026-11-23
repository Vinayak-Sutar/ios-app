import CryptoKit
import Foundation
import NotesCore

/// Titles, captions and thumbnails for the Links page.
///
/// Fetched once per link and kept, because a tile that re-fetched on every
/// render would hammer the sites it points at — and because the page asks for
/// a few at a time precisely so a vault full of links does not become a
/// hundred requests on open.
///
/// The privacy rules are `LinkFetcher`'s and are not relaxed here: hosts that
/// might need the user's account are never contacted, and a thumbnail is
/// fetched only from the link's own page.
@MainActor
final class LinkPreviews {

    struct Preview: Codable, Sendable {
        var key: String
        var title: String
        var caption: String
        var site: String
        var handle: String
        /// Filename under `thumbs/`, or nil. The page builds
        /// `/link-thumb/<thumb>` from it.
        var thumb: String?
        /// What the page shows in place of a preview: "ok", "gone" for a page
        /// that has been taken down, or "none". Also how the page knows not
        /// to ask again — it only fetches tiles with no status.
        var status: String
        /// Set when a fetch was refused or failed, so it is not retried every
        /// time the page opens.
        var failedAt: String?

        /// The fields the Links page merges onto a tile. One function so a
        /// freshly fetched preview and a stored one cannot drift apart —
        /// the page assigns the fetch result straight onto the tile it
        /// already drew.
        var fields: [String: Any] {
            [
                "key": key,
                "title": title,
                "caption": caption,
                "site": site,
                "handle": handle,
                "status": status,
                "thumb": thumb as Any? ?? NSNull()
            ]
        }
    }

    private let vault: Vault
    private let fetcher: LinkFetcher
    private var previews: [String: Preview] = [:]
    private var order: [String] = []

    /// Thumbnails only over HTTPS, and small. A tile is 200 pixels wide; a
    /// multi-megabyte hero image would be downloaded and then thrown away.
    static let maxThumbBytes = 1_500_000

    init(vault: Vault, fetcher: LinkFetcher = LinkFetcher()) {
        self.vault = vault
        self.fetcher = fetcher
        load()
    }

    // MARK: - Where it lives

    private var folder: URL {
        vault.root.appendingPathComponent(".mnemo/links", isDirectory: true)
    }
    private var previewsURL: URL { folder.appendingPathComponent("previews.json") }
    private var layoutURL: URL { folder.appendingPathComponent("layout.json") }
    var thumbsFolder: URL { folder.appendingPathComponent("thumbs", isDirectory: true) }

    private func load() {
        if let data = try? Data(contentsOf: previewsURL),
           let decoded = try? JSONDecoder().decode([String: Preview].self, from: data) {
            previews = decoded
        }
        if let data = try? Data(contentsOf: layoutURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            order = decoded
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(previews) {
            try? data.write(to: previewsURL, options: .atomic)
        }
    }

    // MARK: - Reading

    func preview(for key: String) -> Preview? { previews[key] }

    /// Every thumbnail a stored preview still points at.
    func thumbNames() -> Set<String> {
        Set(previews.values.compactMap(\.thumb))
    }

    /// Drop previews for links that appear in no note any more.
    ///
    /// A link lives in the text of a note, so editing the text can retire one.
    /// Its title and thumbnail then describe something the vault no longer
    /// mentions, and keeping them means the Links page can show a tile for a
    /// link that is not there.
    @discardableResult
    func forget(keysNotIn live: Set<String>) -> Int {
        let stale = previews.keys.filter { !live.contains($0) }
        guard !stale.isEmpty else { return 0 }
        for key in stale { previews.removeValue(forKey: key) }
        order.removeAll { !live.contains($0) }
        save()
        setOrder(order)
        return stale.count
    }

    /// The user's own tile order, with anything new first.
    ///
    /// New links lead rather than trail: a link just saved is the one being
    /// looked for, and appending it below a hand-arranged wall of tiles hides
    /// it exactly when it matters.
    func sort(_ keys: [String]) -> [String] {
        let known = Set(order)
        let fresh = keys.filter { !known.contains($0) }
        let arranged = order.filter { keys.contains($0) }
        return fresh + arranged
    }

    func setOrder(_ keys: [String]) {
        order = keys
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(order) {
            try? data.write(to: layoutURL, options: .atomic)
        }
    }

    // MARK: - Fetching

    /// Fill in up to `max` missing previews.
    ///
    /// Bounded because the page polls this while the Links view is open: a
    /// few at a time keeps the view filling in steadily instead of stalling
    /// on a slow site, and keeps the request count proportional to attention
    /// rather than to vault size.
    func fetchMissing(urls: [(key: String, url: URL)], max: Int = 3) async -> (done: [Preview], left: Int) {
        let pending = urls.filter { previews[$0.key] == nil }
        var done: [Preview] = []

        for item in pending.prefix(max) {
            done.append(await fetchOne(key: item.key, url: item.url))
        }
        save()
        return (done, Swift.max(0, pending.count - done.count))
    }

    private func fetchOne(key: String, url: URL) async -> Preview {
        var preview = Preview(
            key: key,
            title: url.host ?? url.absoluteString,
            caption: "",
            site: url.host ?? "link",
            handle: "",
            thumb: nil,
            status: "ok",
            failedAt: nil
        )

        do {
            let article = try await fetcher.fetch(url)
            preview.title = article.title.ifEmpty(preview.title)
            preview.caption = String(article.description.prefix(200))
            preview.site = article.siteName.ifEmpty(preview.site)
            preview.handle = article.author
            if !article.imageURL.isEmpty,
               let imageURL = URL(string: article.imageURL, relativeTo: url)?.absoluteURL {
                preview.thumb = await fetchThumb(imageURL)
            }
        } catch {
            // Recorded, not retried. A host that refuses once will refuse
            // again, and a tile that re-requests on every open is a tile that
            // gets the user rate-limited.
            preview.failedAt = Timestamp.utcNow()
            if case let LinkFetcher.Refusal.badStatus(code) = error, code == 404 || code == 410 {
                // Worth saying plainly: the page is gone, not merely
                // unreadable, and the user may want to delete the note.
                preview.status = "gone"
            } else {
                preview.status = "none"
            }
            Log.vault.notice("no preview for \(preview.site, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        previews[key] = preview
        return preview
    }

    private func fetchThumb(_ url: URL) async -> String? {
        // HTTPS only: a tile image is not worth a plaintext request, and ATS
        // would refuse it anyway.
        guard url.scheme?.lowercased() == "https", LinkFetcher.shouldFetch(url) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard data.count <= Self.maxThumbBytes else { return nil }
            // By its bytes, not its URL. A link's "image" may be an HTML
            // error page, and storing that under a .jpg helps nobody.
            guard let format = ImageFormat.sniff([UInt8](data.prefix(16))),
                  format == .jpeg || format == .png || format == .webp else {
                return nil
            }

            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
            let name = "\(digest).\(format.fileExtension)"

            try FileManager.default.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
            let target = thumbsFolder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                try data.write(to: target, options: .atomic)
            }
            return name
        } catch {
            return nil
        }
    }

    /// One stored thumbnail, by filename.
    func thumbData(named name: String) -> (Data, String)? {
        guard !name.contains(".."), !name.contains("/"), !name.contains("\\") else { return nil }
        let url = thumbsFolder.appendingPathComponent(name)
        guard url.standardizedFileURL.path.hasPrefix(thumbsFolder.standardizedFileURL.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let format = ImageFormat.sniff([UInt8](data.prefix(16)))
        return (data, format?.contentType ?? "application/octet-stream")
    }
}
