import Foundation
import NotesCore

/// Throwing away what nothing points at any more.
///
/// Images and link thumbnails are content-addressed, so the same screenshot
/// pasted twice is stored once — which also means no single note owns a file
/// and deleting a note cannot simply delete its picture. Nothing deleted them
/// at all, so a vault that had seen a hundred screenshots kept all hundred for
/// ever, and the Links page's thumbnails outlived the links themselves.
///
/// Run at launch rather than on delete, deliberately. Undo restores a deleted
/// note from the Markdown it kept, and a note restored without its picture is
/// worse than a file kept a few minutes too long. The journal is in memory, so
/// by the next launch there is nothing left to undo and nothing left to break.
@MainActor
enum Housekeeping {

    struct Result: Equatable {
        var media = 0
        var thumbs = 0
        var previews = 0
        var skipped: String?

        var summary: String {
            if let skipped { return "skipped: \(skipped)" }
            return "removed \(media) image\(media == 1 ? "" : "s"), "
                + "\(thumbs) thumbnail\(thumbs == 1 ? "" : "s"), "
                + "\(previews) stale link preview\(previews == 1 ? "" : "s")"
        }
    }

    @discardableResult
    static func sweep(vault: Vault, previews: LinkPreviews) -> Result {
        var result = Result()

        // The guard that matters. If the index is empty while files are on
        // disk, the likeliest explanation is a scan that did not finish - and
        // acting on that reading would delete every picture the user has.
        // Deleting nothing is always recoverable; this is not.
        let media = files(in: vault.root.appendingPathComponent(".mnemo/media", isDirectory: true))
        if vault.entries.isEmpty, !media.isEmpty {
            result.skipped = "no notes in the index but \(media.count) files on disk"
            Log.vault.error("housekeeping \(result.summary, privacy: .public)")
            return result
        }

        // One haystack, searched per file: a filename may be referenced by a
        // note's `media` field or written into its body, and both count.
        var haystack = ""
        for entry in vault.entries.values {
            if let path = entry.note.media { haystack += path + "\n" }
            haystack += entry.note.body + "\n"
        }

        for url in media where !haystack.contains(url.lastPathComponent) {
            if remove(url) { result.media += 1 }
        }

        // A preview for a link that appears in no note is a preview of
        // nothing. Dropping it also releases its thumbnail.
        let live = Set(RouteTable.linkIndex(vault).map(\.key))
        result.previews = previews.forget(keysNotIn: live)

        let kept = previews.thumbNames()
        for url in files(in: previews.thumbsFolder) where !kept.contains(url.lastPathComponent) {
            if remove(url) { result.thumbs += 1 }
        }

        Log.vault.notice("housekeeping \(result.summary, privacy: .public)")
        return result
    }

    /// Regular files directly inside one folder. Not recursive: these two
    /// folders are flat, and a sweep that walked into somewhere unexpected is
    /// exactly the sweep nobody wants.
    private static func files(in folder: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        )
        return (contents ?? []).filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private static func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            Log.vault.error(
                "could not remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
