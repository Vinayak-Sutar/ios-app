import NotesCore
import SwiftUI
import UIKit
import WebKit

@main
struct AdvancedNotesApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .ignoresSafeArea(.keyboard)
        }
    }
}

/// The entire native UI: one web view, plus a readable failure state.
///
/// There is deliberately almost no SwiftUI here. The interface is the Windows
/// app's `app.html`, served by the in-process HTTP server, which means the
/// largest and least verifiable part of a native port — rebuilding that UI
/// blind, with no previews and no Simulator on this machine — simply does not
/// have to happen. What is left written blind is the bridge.
struct RootView: View {
    @StateObject private var host = WebHost()

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()

            switch host.phase {
            case .starting:
                ProgressView("Starting…")

            case let .ready(url):
                WebView(
                    url: url.appendingPathComponent(host.page.path),
                    reloadToken: host.reloadToken
                )
                .ignoresSafeArea()

                // The diagnostics page is served at /diag, but a WKWebView has
                // no address bar, so without this it is unreachable — and it
                // is the only instrument this app has. Small and quiet, in the
                // corner the page keeps clear.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(host.page == .app ? "diag" : "notes") {
                            host.togglePage()
                        }
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .opacity(0.65)
                        .padding(.trailing, 10)
                        .padding(.bottom, 2)
                    }
                }

            case let .failed(message):
                // Without a debugger a silent failure is undiagnosable, so the
                // reason goes on screen where it can be read and shared.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Could not start")
                            .font(.title2.bold())
                        Text(message)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Button("Try again") { host.start() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { host.start() }
    }
}

/// Owns the server's lifetime and tells the web view when to reload.
@MainActor
final class WebHost: ObservableObject {

    enum Phase {
        case starting
        case ready(URL)
        case failed(String)
    }

    /// Which page the web view shows. The app itself, or the diagnostics page.
    enum Page: Equatable {
        case app
        case diag

        var path: String { self == .app ? "" : "diag" }
    }

    @Published private(set) var page: Page = .app
    @Published private(set) var phase: Phase = .starting
    /// Bumped whenever the page needs reloading — after a cold start and after
    /// every return to the foreground, because the listening socket does not
    /// survive suspension.
    @Published private(set) var reloadToken = 0

    private let server = LocalServer()
    private var started = false
    private var foregroundObserver: NSObjectProtocol?

    // Kept alive for the app's lifetime: the vault holds the in-memory index
    // and the embedder holds loaded model assets, so neither should be rebuilt
    // per request.
    private var vault: Vault?
    private var embedding: EmbedderBox?
    private var capture: Capture?
    private var diagnostics: Diagnostics?
    private var chat: Chat?
    private var reminders: Reminders?

    func togglePage() {
        page = (page == .app) ? .diag : .app
        reloadToken += 1
    }

    func start() {
        guard !started else { return }
        started = true

        Task {
            let vault = Vault()
            let embedding = EmbedderBox()
            let intelligence = Intelligence()

            do {
                try vault.prepare()
            } catch {
                phase = .failed("could not create the vault: \(error.localizedDescription)")
                started = false
                return
            }

            // Serve the page as soon as the port is up. Loading the embedder's
            // assets can take a while on a fresh install, and the vault scan
            // grows with the note count — neither should hold the UI back,
            // because an unembedded note still saves, it just lands in Inbox.
            let capture = Capture(
                vault: vault,
                intelligence: intelligence,
                embedding: embedding,
                thresholds: Thresholds.appleGuess(embedderID: "pending")
            )
            let diagnostics = Diagnostics(embedding: embedding)
            let chat = Chat(vault: vault, embedding: embedding, thresholds: { capture.thresholds })
            let reminders = Reminders(vault: vault)

            self.vault = vault
            self.embedding = embedding
            self.capture = capture
            self.diagnostics = diagnostics
            self.chat = chat
            self.reminders = reminders

            let routes = RouteTable(
                diagnostics: diagnostics,
                vault: vault,
                capture: capture,
                embedding: embedding,
                chat: chat,
                reminders: reminders,
                intelligence: intelligence
            )
            await server.install(routes)
            await server.start()

            DevOverrides.writeTemplateIfMissing(in: vault.root)
            let (overrides, _) = DevOverrides.load()
            if let coldStart = overrides.coldStartNotes { capture.coldStartNotes = coldStart }
            if let retrievalOnly = overrides.retrievalOnly { capture.retrievalOnly = retrievalOnly }

            Task {
                await embedding.prepare()
                let base = Thresholds.appleGuess(embedderID: embedding.identifier)
                let (merged, rejected) = overrides.apply(to: base)
                capture.thresholds = merged
                for note in rejected {
                    Log.vault.error("override ignored: \(note, privacy: .public)")
                }
                await vault.reload(using: embedding.embedder)

                // Ask only after the vault is loaded, so the prompt arrives
                // when there is something to be reminded about rather than on
                // a blank first launch.
                await reminders.requestAuthorization()
                // Pending notifications survive a relaunch but not a
                // reinstall, and a 7-day sideload means reinstalling weekly.
                await reminders.rescheduleAll()
            }

            let snapshot = await server.snapshot()
            if snapshot.state == .listening {
                phase = .ready(await server.baseURL)
            } else {
                phase = .failed(snapshot.lastError ?? "the local server never started listening")
                started = false
            }

            observeForeground()
        }
    }

    private func observeForeground() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // iOS hangs up the listening socket on suspend. Bring it back
                // before reloading, or the page loads against a dead port and
                // shows a blank screen with no explanation.
                await self.server.resume()
                let snapshot = await self.server.snapshot()
                if snapshot.state == .listening {
                    self.phase = .ready(await self.server.baseURL)
                    self.reloadToken += 1
                }
            }
        }
    }
}

/// A plain `WKWebView`. Nothing is injected into the page: `app.html` runs
/// exactly as it does in a desktop browser against the Python server, which is
/// what makes it possible to develop the UI on Windows.
struct WebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The page is served from loopback, so there is nothing to gain from
        // letting it open other origins.
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // The page draws its own background; a white flash between loads is
        // jarring on a dark palette.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        context.coordinator.loadedToken = reloadToken
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedToken != reloadToken else { return }
        context.coordinator.loadedToken = reloadToken
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Reports what the web view actually did.
    ///
    /// Without this a failed load is completely silent: the view stays blank
    /// and nothing anywhere says whether the request was refused, timed out or
    /// succeeded and then rendered nothing. Those need different fixes, so the
    /// log has to distinguish them.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedToken = -1

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Log.routes.notice("web view loaded \(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            // "Provisional" means it never even started loading — a refused
            // connection or a blocked request, not a page that failed later.
            Log.routes.error("web view could not start loading: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.routes.error("web view failed mid-load: \(error.localizedDescription, privacy: .public)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The renderer was killed, usually for memory. A 1.5 MB page with
            // embedded fonts is a plausible cause, and it looks like a blank
            // screen from the outside.
            Log.routes.error("web content process terminated; reloading")
            webView.reload()
        }
    }
}
