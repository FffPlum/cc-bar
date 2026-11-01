import Foundation
import WebKit

/// A bridge must be installed explicitly by the owner of a future web view.
/// No web view is created or connected during app startup.
@MainActor
final class MacOSWebKitTransport: NSObject {
    static let handlerName = "ccbarHost"
    private static var owners: [ObjectIdentifier: WeakTransport] = [:]
    private let service: MacOSHostService
    private let trustedURL: URL
    private weak var webView: WKWebView?
    private weak var controller: WKUserContentController?
    private var subscription: UUID?
    private var generation = 0

    init(service: MacOSHostService, trustedURL: URL) {
        self.service = service
        self.trustedURL = trustedURL
    }

    @discardableResult
    func install(on webView: WKWebView) -> Bool {
        let target = webView.configuration.userContentController
        let key = ObjectIdentifier(target)
        if let owner = Self.owners[key]?.value, owner !== self { return false }
        uninstall()
        // A dead owner may have left WebKit's weak proxy registered.
        target.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        self.webView = webView
        let controller = target
        self.controller = controller
        Self.owners[key] = WeakTransport(self)
        controller.addScriptMessageHandler(WeakHostMessageHandler(owner: self), contentWorld: .page, name: Self.handlerName)
        subscription = service.subscribe { [weak self] event in self?.send(event) }
        return true
    }

    func uninstall() {
        generation += 1
        if let subscription { service.unsubscribe(subscription); self.subscription = nil }
        if let controller {
            let key = ObjectIdentifier(controller)
            if Self.owners[key]?.value === self {
                controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
                Self.owners.removeValue(forKey: key)
            }
        }
        controller = nil
        webView = nil
    }

    static func isTrusted(mainFrame: Bool, url: URL?, trustedURL: URL) -> Bool {
        guard mainFrame, let url, let scheme = url.scheme?.lowercased(), scheme == trustedURL.scheme?.lowercased() else { return false }
        if scheme == "file" { return url.standardizedFileURL == trustedURL.standardizedFileURL }
        guard scheme == "https", let host = url.host?.lowercased(), host == trustedURL.host?.lowercased() else { return false }
        return (url.port ?? 443) == (trustedURL.port ?? 443)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.webView === webView,
              Self.isTrusted(mainFrame: message.frameInfo.isMainFrame, url: message.frameInfo.request.url, trustedURL: trustedURL),
              JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let request = try? JSONDecoder().decode(HostRequest.self, from: data) else {
            replyHandler(nil, "Untrusted frame or invalid request")
            return
        }
        let requestGeneration = generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == requestGeneration, self.webView === message.webView else { replyHandler(nil, "Host unavailable"); return }
            let response = await self.service.handle(request)
            guard let data = try? JSONEncoder().encode(response), let object = try? JSONSerialization.jsonObject(with: data) else {
                replyHandler(nil, "Unable to encode response"); return
            }
            replyHandler(object, nil)
        }
    }

    private func send(_ event: HostEvent) {
        guard let webView, Self.isTrusted(mainFrame: true, url: webView.url, trustedURL: trustedURL),
              let data = try? JSONEncoder().encode(event), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__ccbarHostReceiveEvent?.(\(json))", completionHandler: nil)
    }
}

/// WebKit owns its handler; the proxy does not keep the transport alive.
@MainActor
private final class WeakHostMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: MacOSWebKitTransport?

    init(owner: MacOSWebKitTransport) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "Host unavailable"); return }
        owner.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }
}

@MainActor
private final class WeakTransport {
    weak var value: MacOSWebKitTransport?
    init(_ value: MacOSWebKitTransport) { self.value = value }
}
