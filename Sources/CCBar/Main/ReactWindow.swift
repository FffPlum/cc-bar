import AppKit
import SwiftUI
import WebKit

@MainActor
final class ReactWindowController: NSObject {
    /// Set CCBAR_REACT_MAIN_WINDOW=0 only to compare with the native development fallback.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CCBAR_REACT_MAIN_WINDOW"] != "0"
    }

    let contentView = NSView()
    private let service: MacOSHostService
    private let transport: MacOSWebKitTransport
    private let schemeHandler = WebInterfaceSchemeHandler()
    private let webView: WKWebView
    private var isDisposed = false
    private lazy var recoveryView = NSHostingView(rootView: ReactWindowRecoveryView(message: "", retry: { [weak self] in
        self?.load()
    }))

    init(service: MacOSHostService) {
        self.service = service
        transport = MacOSWebKitTransport(service: service, trustedURL: WebInterfaceBundle.entryURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: WebInterfaceBundle.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configureContentView()
    }

    func load() {
        guard !isDisposed else { return }
        showWebContent()
        guard WebInterfaceBundle.indexFileURL != nil else {
            showRecovery("Bundled index is missing")
            return
        }
        guard transport.install(on: webView) else {
            showRecovery("Host bridge installation failed")
            return
        }
        webView.load(URLRequest(url: WebInterfaceBundle.entryURL))
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        transport.uninstall()
        service.invalidate()
        webView.configuration.setURLSchemeHandler(nil, forURLScheme: WebInterfaceBundle.scheme)
    }

    private func configureContentView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        contentView.addSubview(webView)

        recoveryView.translatesAutoresizingMaskIntoConstraints = false
        recoveryView.isHidden = true
        contentView.addSubview(recoveryView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            recoveryView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            recoveryView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            recoveryView.topAnchor.constraint(equalTo: contentView.topAnchor),
            recoveryView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func showWebContent() {
        recoveryView.isHidden = true
        webView.isHidden = false
    }

    private func showRecovery(_ reason: String) {
        AppLog.error(.app, "React window unavailable: \(Redact.scrub(reason))")
        transport.uninstall()
        webView.stopLoading()
        webView.isHidden = true
        recoveryView.rootView = ReactWindowRecoveryView(
            message: tr("Retry to load the window.", "请重试。"),
            retry: { [weak self] in self?.load() }
        )
        recoveryView.isHidden = false
    }
}

extension ReactWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, navigationAction.sourceFrame.isMainFrame else { return .cancel }
        if navigationAction.targetFrame?.isMainFrame == true, WebInterfaceBundle.isMainDocumentURL(url) {
            return .allow
        }
        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        presentNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        presentNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showRecovery("Web content process terminated")
    }

    private func presentNavigationFailure(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
        showRecovery("Navigation failed: \(Redact.error(error))")
    }
}

extension ReactWindowController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

private struct ReactWindowRecoveryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(tr("Application window unavailable", "应用窗口暂时无法加载"))
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(tr("Retry", "重试"), action: retry)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
