import FlyingFox
import Foundation

/// Building HTTP responses, deliberately outside any actor.
///
/// Five of the six iOS compile failures on this project have been the same
/// thing: a helper that lives on the `@MainActor` bridge, called from one of
/// FlyingFox's `@Sendable` route handlers. Each was fixed by adding
/// `nonisolated` to one more declaration, which fixes the instance and leaves
/// the trap.
///
/// So these live here instead, in a top-level type with no isolation to
/// inherit. A new route cannot reintroduce the problem by forgetting an
/// annotation, because there is no annotation to forget. None of this touches
/// app state — it turns a value into bytes.
enum Respond {

    static func json(_ value: some Encodable, status: HTTPStatusCode = .ok) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data(#"{"error":"encoding failed"}"#.utf8)
        return HTTPResponse(
            statusCode: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: body
        )
    }

    /// Named separately rather than overloaded on `json`: a dictionary with a
    /// uniform value type satisfies both, and an ambiguity here costs a round
    /// trip to a CI runner to discover.
    static func jsonObject(_ value: [String: Any], status: HTTPStatusCode = .ok) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: value))
            ?? Data(#"{"error":"encoding failed"}"#.utf8)
        return HTTPResponse(
            statusCode: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: body
        )
    }

    /// Newline-delimited JSON, which is how the chat stream is framed.
    static func ndjson(_ lines: [String]) -> HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/x-ndjson; charset=utf-8"],
            body: Data((lines.joined(separator: "\n") + "\n").utf8)
        )
    }

    static func ndjson(_ data: Data) -> HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/x-ndjson; charset=utf-8"],
            body: data
        )
    }

    static func text(_ body: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/plain; charset=utf-8"],
            body: Data(body.utf8)
        )
    }

    static func failure(_ message: String, status: HTTPStatusCode) -> HTTPResponse {
        json(API.Failure(error: message), status: status)
    }

    // MARK: - Static files

    static func bundled(_ name: String, _ ext: String) -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            Log.routes.error("missing bundled resource \(name, privacy: .public).\(ext, privacy: .public)")
            return HTTPResponse(
                statusCode: .internalServerError,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: Data("missing \(name).\(ext) in the app bundle".utf8)
            )
        }
        var headers: HTTPHeaders = [.contentType: contentType(for: ext)]
        // The page looks for this header on itself.
        if ext == "html" { headers[HTTPHeader("X-Notes-App")] = "1" }
        return HTTPResponse(statusCode: .ok, headers: headers, body: data)
    }

    static func contentType(for ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Reading requests

    static func query(_ request: HTTPRequest) -> [String: String] {
        var out: [String: String] = [:]
        for item in request.query { out[item.name] = item.value }
        return out
    }

    /// A missing or malformed body reads as empty rather than throwing. Every
    /// route already has to handle a missing field, so there is nothing for a
    /// separate parse error to add.
    static func body(_ request: HTTPRequest) async throws -> [String: Any] {
        let data = try await request.bodyData
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return parsed
    }
}
