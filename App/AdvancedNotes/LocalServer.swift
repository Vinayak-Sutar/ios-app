import FlyingFox
// Not re-exported by FlyingFox, and the IPv4 address factories live here.
import FlyingSocks
import Foundation

/// A real HTTP server, bound to loopback, inside the app.
///
/// The whole interface is the Windows app's `web/app.html` — 5,811 lines of
/// self-contained HTML that talks to its backend only through relative
/// `fetch('/api/…')` calls, POSTs JSON bodies, and reads a newline-delimited
/// JSON stream for chat. Giving it an actual HTTP server makes every one of
/// those assumptions true, so the page runs byte-for-byte unchanged. A custom
/// `WKURLSchemeHandler` would need the POST body read off a stream and makes
/// streaming responses awkward; this costs one dependency instead.
///
/// `http://127.0.0.1` is also a secure context, so nothing in the page takes a
/// downgrade path.
///
/// **The suspend problem.** iOS hangs up the listening socket when the app is
/// suspended; on return `run()` throws `SocketError.disconnected` and the
/// server has to be started again. That is handled here from the start, by a
/// supervisor loop, because discovered later it presents as a blank screen with
/// no obvious cause.
actor LocalServer {

    enum State: Equatable {
        case idle
        case listening
        case restarting(String)
    }

    let port: UInt16
    private let server: HTTPServer
    private var supervisor: Task<Void, Never>?
    private(set) var state: State = .idle
    private(set) var restarts = 0
    private(set) var lastError: String?

    init(port: UInt16 = 8787) {
        self.port = port
        // IPv4 loopback, explicitly.
        //
        // FlyingFox's `.loopback(port:)` is declared on `sockaddr_in6`, so it
        // binds `::1` and nothing else. The web view dials `127.0.0.1`, which
        // is IPv4 — so the bind succeeded, `waitUntilListening()` returned,
        // the app reported itself healthy, and every request was refused.
        // That presented as a blank page with the server insisting it was
        // listening.
        //
        // Still loopback rather than any-interface: nothing here should be
        // reachable from the network, and binding says so rather than trusting
        // a check later.
        // No fallback on purpose. The obvious one, `.inet(port:)`, is
        // INADDR_ANY — every interface — which would quietly put the notes on
        // the Wi-Fi. A dotted quad literal cannot fail to parse, so a trap
        // here is unreachable and preferable to that.
        guard let address = try? sockaddr_in.inet(ip4: "127.0.0.1", port: port) else {
            preconditionFailure("127.0.0.1 did not parse as an IPv4 address")
        }
        self.server = HTTPServer(address: address)
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func install(_ routes: RouteTable) async {
        await routes.install(on: server)
    }

    /// Starts the server if it is not already running, and waits until it is
    /// actually accepting connections so the web view is never pointed at a
    /// dead port.
    func start() async {
        if supervisor == nil {
            supervisor = Task { [server] in
                var attempt = 0
                while !Task.isCancelled {
                    do {
                        try await server.run()
                        Log.server.notice("server stopped cleanly")
                    } catch {
                        // Expected every time the app is suspended and resumed.
                        Log.server.notice("server stopped: \(error.localizedDescription, privacy: .public)")
                    }
                    if Task.isCancelled { break }
                    attempt += 1
                    // Backs off a little so a genuinely unusable port does not
                    // spin, but stays quick enough that resuming feels instant.
                    let delay = min(2_000_000_000, 100_000_000 * UInt64(attempt))
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        do {
            try await server.waitUntilListening()
            state = .listening
            Log.server.notice("listening on 127.0.0.1:\(self.port, privacy: .public)")
        } catch {
            state = .restarting(error.localizedDescription)
            lastError = error.localizedDescription
            Log.server.error("never started listening: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called when the app comes back to the foreground. The socket is almost
    /// certainly gone, so this makes sure the supervisor has brought it back
    /// before the web view reloads.
    func resume() async {
        restarts += 1
        await start()
    }

    func stop() async {
        supervisor?.cancel()
        supervisor = nil
        await server.stop(timeout: 1)
        state = .idle
    }

    func snapshot() -> (state: State, restarts: Int, lastError: String?) {
        (state, restarts, lastError)
    }
}
