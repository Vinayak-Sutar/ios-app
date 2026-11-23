import Foundation

/// Writing a file so that it is never half there.
///
/// The Markdown files are the truth, so a note interrupted mid-write is the
/// one failure the storage layer must not have: the staging file is written
/// whole and then swapped in, which is a rename rather than a copy.
///
/// Staging goes in Caches rather than beside the note, for two reasons that
/// both matter. Same volume, so the replace stays a rename — and the vault is
/// visible in the Files app, where a stray `write-E4C1….tmp` next to someone's
/// notes looks like the app leaking.
///
/// One copy of this, used by both the vault and the diagnostics probe. It was
/// written out twice, which is one way to find out later that only one of them
/// was fixed.
enum AtomicFile {

    static func write(_ text: String, to url: URL) throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let staging = caches.appendingPathComponent("write-\(UUID().uuidString).tmp")

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: staging, options: .atomic)

        // `replaceItemAt` needs something to replace; a first write has
        // nothing there yet.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
    }
}
