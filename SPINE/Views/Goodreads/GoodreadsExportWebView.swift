//
//  GoodreadsExportWebView.swift
//  SPINE
//
//  Embedded browser for the Goodreads (or StoryGraph) export page. Three jobs:
//  1. Keep navigation inside Spine — goodreads.com registers a catch-all
//     universal link, so opening the page externally hands off to the Goodreads
//     app (where the CSV can't be downloaded). Embedded web views are mostly
//     immune, EXCEPT user-gesture navigations that cross domains and land back
//     on goodreads.com (the Sign in with Apple redirect chain does exactly
//     this) — those can still trigger the handoff, so every navigation is
//     allowed with WebKit's "without app link" policy (see Coordinator).
//  2. Intercept the library-export CSV download via WKDownloadDelegate and feed
//     the parsed rows straight back to the import wizard — no Files app, no
//     upload step.
//  3. Guide the two-visit dance: Goodreads bounces an unauthenticated visit to
//     its login page and then strands the user on the homepage (not back on the
//     export page), so the wizard opens this view twice — once in `.login` mode
//     ("sign in, then tap I'm logged in") and once in `.export` mode. Same URL
//     both times.
//
//  StoryGraph is simpler: its sign-in page bounces straight back to the
//  export page, so it's a single `.export` visit. The catch there is that the
//  export is generated asynchronously (about a minute) and the download link
//  only appears after a reload, so this view adds pull-to-refresh and a
//  Refresh button that re-opens the export page.
//

import SwiftUI
import WebKit

/// The "Your export from MM/DD/YYYY…" link on the Goodreads export page,
/// mimicked inside our instructions — Goodreads' own link teal + underline,
/// today's date — so users recognize the real link as tappable. (Users read
/// the quoted instruction and still didn't realize the link was pushable.)
enum GoodreadsExportLinkMock {
    /// Goodreads' anchor color (#00635D) — intentionally off-palette so the
    /// mock matches the real page, not SPINE chrome.
    static let color = Color(red: 0 / 255, green: 99 / 255, blue: 93 / 255)

    static var text: Text {
        Text("Your export from \(dateStamp)…")
            .foregroundColor(color)
            .underline()
    }

    private static var dateStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.string(from: Date())
    }
}

struct GoodreadsExportWebView: View {
    /// Which step of the two-visit import flow this browser visit is for.
    enum Mode {
        case login
        case export
    }

    var source: LibraryImportSource = .goodreads
    var mode: Mode = .export
    /// Login mode only: the user tapped "I'm logged in" — the wizard advances
    /// to the export step.
    var onLoggedIn: () -> Void = {}
    /// Called with the parsed export when the user's CSV is captured.
    let onExport: (LibraryExport) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDownloading = false
    @State private var errorMessage: String?
    /// Bumped by the Refresh button; the web view re-opens the export page.
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                GoodreadsExportWebViewRepresentable(
                    source: source,
                    isDownloading: $isDownloading,
                    errorMessage: $errorMessage,
                    reloadToken: reloadToken,
                    onExport: onExport
                )
                .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mode == .login ? "Cancel" : "Close") { dismiss() }
                        .foregroundStyle(mode == .login ? Theme.textTertiary : Theme.accent)
                }
                if mode == .login {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onLoggedIn()
                        } label: {
                            Text("I’m logged in")
                                .font(Theme.callout())
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                } else if source == .storyGraph {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            errorMessage = nil
                            reloadToken += 1
                        } label: {
                            Text("Refresh")
                                .font(Theme.callout())
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        switch source {
        case .goodreads: return mode == .login ? "Log in to Goodreads" : "Goodreads export"
        case .storyGraph: return "StoryGraph export"
        }
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isDownloading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Theme.accent)
                    Text("Grabbing your export…")
                        .font(Theme.callout())
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                }
            } else if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.danger)
                    Text(errorMessage)
                        .font(Theme.callout())
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(SpinesGlyphs.caps(stepLabel))
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.chrome)
                instructionText
                    .font(Theme.callout())
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surfaceElevated)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.chrome.opacity(0.35))
                .frame(height: Theme.chromeHairline)
        }
    }

    private var stepLabel: String {
        switch source {
        case .goodreads: return mode == .login ? "Step 1 of 2" : "Step 2 of 2"
        case .storyGraph: return "Takes about a minute"
        }
    }

    private var instructionText: Text {
        switch source {
        case .goodreads:
            if mode == .login {
                return Text("Sign in to Goodreads, then tap “I’m logged in” at the top. If your phone opens the Goodreads app, close it and come back to SPINE.")
            } else {
                return Text("Tap “Export Library”, then tap the ")
                    + GoodreadsExportLinkMock.text
                    + Text(" link when it appears.")
            }
        case .storyGraph:
            return Text("Sign in if asked, then tap “Generate export”. It usually takes about a minute. Stay on this page and tap Refresh (or pull down) until a download link appears, then tap it. No need to check your email.")
        }
    }
}

// MARK: - WKWebView wrapper

private struct GoodreadsExportWebViewRepresentable: UIViewRepresentable {
    let source: LibraryImportSource
    @Binding var isDownloading: Bool
    @Binding var errorMessage: String?
    /// Re-opens the export page whenever this changes (Refresh button).
    var reloadToken: Int
    let onExport: (LibraryExport) -> Void

    static func exportPageURL(for source: LibraryImportSource) -> URL {
        switch source {
        case .goodreads: return URL(string: "https://www.goodreads.com/review/import")!
        case .storyGraph: return URL(string: "https://app.thestorygraph.com/user-export")!
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Default (persistent) store so the login survives between imports.
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if source == .storyGraph {
            // The generated export only shows up after a reload; pull-to-refresh
            // is the gesture people reach for first.
            let refresh = UIRefreshControl()
            refresh.addTarget(context.coordinator, action: #selector(Coordinator.pullToRefresh(_:)), for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }
        context.coordinator.webView = webView
        context.coordinator.appliedReloadToken = reloadToken
        webView.load(URLRequest(url: Self.exportPageURL(for: source)))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.appliedReloadToken != reloadToken {
            context.coordinator.appliedReloadToken = reloadToken
            uiView.load(URLRequest(url: Self.exportPageURL(for: source)))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let parent: GoodreadsExportWebViewRepresentable
        private var downloadDestination: URL?
        weak var webView: WKWebView?
        var appliedReloadToken = 0

        @objc func pullToRefresh(_ control: UIRefreshControl) {
            parent.errorMessage = nil
            webView?.load(URLRequest(url: GoodreadsExportWebViewRepresentable.exportPageURL(for: parent.source)))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        /// WebKit's "allow without trying the app link" policy (allow + 2).
        /// Plain .allow lets iOS hand user-gesture cross-domain navigations
        /// back to goodreads.com (e.g. the Sign in with Apple redirect) off to
        /// the Goodreads app, which strands the export flow there. Falls back
        /// to .allow if the raw value ever stops resolving.
        private static let allowInWebView =
            WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

        init(_ parent: GoodreadsExportWebViewRepresentable) {
            self.parent = parent
        }

        // Login providers sometimes open target=_blank windows — load them in place instead.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : Self.allowInWebView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
            let filename = navigationResponse.response.suggestedFilename?.lowercased() ?? ""
            let looksLikeCSV = mime.contains("csv") || filename.hasSuffix(".csv")
            if looksLikeCSV || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
            parent.isDownloading = true
            parent.errorMessage = nil
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            parent.isDownloading = true
            parent.errorMessage = nil
        }

        // MARK: WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("library-export-\(UUID().uuidString).csv")
            downloadDestination = url
            completionHandler(url)
        }

        func downloadDidFinish(_ download: WKDownload) {
            parent.isDownloading = false
            guard let url = downloadDestination, let data = try? Data(contentsOf: url) else {
                parent.errorMessage = "Couldn't read the export. Tap the export link again."
                return
            }
            defer { try? FileManager.default.removeItem(at: url) }
            downloadDestination = nil
            if let export = LibraryExportParser.parse(data: data) {
                parent.onExport(export)
            } else {
                switch parent.source {
                case .goodreads:
                    parent.errorMessage = "That file didn't look like a Goodreads export. Tap the “Your export from…” link, not another download."
                case .storyGraph:
                    parent.errorMessage = "That file didn't look like a StoryGraph export. Tap the download link for your export, not another download."
                }
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            parent.isDownloading = false
            parent.errorMessage = "Download failed. Check your connection and tap the export link again."
        }
    }
}
