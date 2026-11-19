import Foundation
import NotesCore

/// The vault on disk, and proof that it works.
///
/// Notes live in `Documents/Vault/<Collection>/<slug>.md`. With
/// `UIFileSharingEnabled` set, that folder appears in the Files app under
/// *On My iPhone ▸ Advanced Notes*, which serves two purposes: it keeps the
/// product's promise that notes are plain files you can open, and — with no
/// debugger available — it makes the frontmatter the app writes directly
/// readable. The filing decision can be inspected by opening the file.
@MainActor
final class VaultProbe {

    let root: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = documents.appendingPathComponent("Vault", isDirectory: true)
    }

    var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    /// Writes a note, reads it back, and compares. An M0 round trip that proves
    /// the codec and the container agree before any real note depends on it.
    func roundTripCheck() -> (ok: Bool, detail: String?) {
        let note = Note(
            title: "Storage check",
            body: "Written by the diagnostics page. Safe to delete.",
            topics: []
        )
        let url = inbox.appendingPathComponent("storage-check.md")
        do {
            try ensureDirectories()
            try writeAtomically(FrontmatterCodec.render(note), to: url)
            let text = try String(contentsOf: url, encoding: .utf8)
            let reloaded = FrontmatterCodec.load(text)
            try? FileManager.default.removeItem(at: url)

            guard reloaded.id == note.id, reloaded.title == note.title, reloaded.body == note.body else {
                return (false, "round trip changed the note")
            }
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Write to a temporary file and replace, so a note can never be left
    /// half-written. The temp file goes in Caches rather than beside the note,
    /// both because it is on the same volume (making the replace a rename) and
    /// so stray `.tmp` files never appear in the user's Files view.
    func writeAtomically(_ text: String, to url: URL) throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let staging = caches.appendingPathComponent("write-\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
    }

    func markdownFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
    }

    func info() -> Diagnostics.StorageInfo {
        let sharing = Bundle.main.infoDictionary?["UIFileSharingEnabled"] as? Bool ?? false
        let check = roundTripCheck()
        return Diagnostics.StorageInfo(
            vaultPath: root.path,
            visibleInFilesApp: sharing,
            writable: check.ok,
            detail: check.detail,
            noteCount: markdownFiles().count
        )
    }
}
