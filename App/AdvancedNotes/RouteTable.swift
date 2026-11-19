import FlyingFox
import Foundation
import NotesCore

/// The `/api/…` surface the web UI talks to.
///
/// For M0 this serves only the diagnostics page: the point of the first
/// milestone is to prove a build can be signed and installed and that the model
/// and embedder are reachable from app code. The real routes — `/api/state`,
/// `/api/capture` and the rest — arrive in M1, written against JSON recorded
/// from the Python server rather than guessed at.
@MainActor
final class RouteTable {

    private let diagnostics: Diagnostics

    init(diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
    }

    func install(on server: HTTPServer) async {
        await server.appendRoute("GET /api/diag") { [diagnostics] _ in
            let report = await diagnostics.report()
            return Self.json(report)
        }

        await server.appendRoute("POST /api/diag/probe") { [diagnostics] _ in
            let report = await diagnostics.runProbes()
            return Self.json(report)
        }

        await server.appendRoute("GET /api/diag/log") { _ in
            let text = Log.recentEntries().joined(separator: "\n")
            return HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: Data(text.utf8)
            )
        }

        // The page itself. `/` and `/diag` both land here for now.
        await server.appendRoute("GET /") { _ in Self.bundled("diag", "html") }
        await server.appendRoute("GET /diag") { _ in Self.bundled("diag", "html") }

        // The page may try to register a service worker because loopback is a
        // secure context. It is not needed — the server is always local — so
        // answer with a no-op rather than letting a 404 surface as an error.
        await server.appendRoute("GET /sw.js") { _ in
            HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "text/javascript; charset=utf-8"],
                body: Data("// intentionally empty: this app has no offline copy to manage\n".utf8)
            )
        }

        await server.appendRoute("GET *") { request in
            Log.routes.notice("unhandled: \(request.path, privacy: .public)")
            return HTTPResponse(
                statusCode: .notFound,
                headers: [.contentType: "application/json"],
                body: Data("{\"error\":\"not found\"}".utf8)
            )
        }
    }

    // MARK: - Helpers
    //
    // These are `nonisolated` because the route closures are `@Sendable` and
    // therefore not on the main actor, while the class is. They touch no
    // instance state — they encode a value or read a file out of the bundle —
    // so there is nothing for the isolation to protect.

    nonisolated static func json(_ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: body
        )
    }

    nonisolated static func bundled(_ name: String, _ ext: String) -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            Log.routes.error("missing bundled resource \(name, privacy: .public).\(ext, privacy: .public)")
            return HTTPResponse(
                statusCode: .internalServerError,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: Data("missing \(name).\(ext) in the app bundle".utf8)
            )
        }
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: contentType(for: ext)],
            body: data
        )
    }

    nonisolated static func contentType(for ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
