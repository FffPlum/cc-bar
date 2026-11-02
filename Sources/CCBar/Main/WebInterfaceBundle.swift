import Foundation
import WebKit

struct WebInterfaceBundle {
    static let scheme = "ccbar-ui"
    static let host = "app"
    static let entryURL = URL(string: "ccbar-ui://app/index.html")!

    static var indexFileURL: URL? {
        try? resourceFileURL(for: entryURL)
    }

    static func isTrustedResourceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == host
            && url.port == nil
            && url.user == nil
            && url.password == nil
    }

    static func isMainDocumentURL(_ url: URL) -> Bool {
        isTrustedResourceURL(url) && url.path == entryURL.path
    }

    static func resourceFileURL(for url: URL) throws -> URL {
        guard let bundleRoot = ResourceBundle.app.resourceURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            throw WebInterfaceResourceError.missing
        }
        return try resourceFileURL(for: url, bundleRoot: bundleRoot)
    }

    static func resourceFileURL(for url: URL, bundleRoot: URL) throws -> URL {
        guard isTrustedResourceURL(url), url.path.hasPrefix("/") else {
            throw WebInterfaceResourceError.invalidRequest
        }
        let components = url.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && !component.contains("\\") && !component.contains("\0")
        }) else {
            throw WebInterfaceResourceError.invalidRequest
        }
        let bundleRoot = bundleRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let root = resourceRoot(containedIn: bundleRoot) else {
            throw WebInterfaceResourceError.missing
        }
        let relativePath = components.joined(separator: "/")
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard isDescendant(fileURL, of: root) else {
            throw WebInterfaceResourceError.outsideRoot
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw WebInterfaceResourceError.missing
        }
        return fileURL
    }

    private static func resourceRoot(containedIn bundleRoot: URL) -> URL? {
        let root = bundleRoot.appendingPathComponent("WebInterface", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard isDescendant(root, of: bundleRoot),
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return root
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        url.path != root.path && url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }
}

enum WebInterfaceResourceError: LocalizedError {
    case invalidRequest
    case missing
    case outsideRoot

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "Invalid web interface resource request"
        case .missing: "Web interface resource is missing"
        case .outsideRoot: "Web interface resource escapes its bundle directory"
        }
    }
}

@MainActor
final class WebInterfaceSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let contentSecurityPolicy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'; frame-ancestors 'none'; worker-src 'self'"
    private let bundleRoot: URL?

    override init() {
        bundleRoot = nil
        super.init()
    }

    init(bundleRoot: URL) {
        self.bundleRoot = bundleRoot
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard let method = urlSchemeTask.request.httpMethod?.uppercased(), method == "GET" || method == "HEAD",
                  let url = urlSchemeTask.request.url else {
                throw WebInterfaceResourceError.invalidRequest
            }
            let fileURL: URL
            if let bundleRoot {
                fileURL = try WebInterfaceBundle.resourceFileURL(for: url, bundleRoot: bundleRoot)
            } else {
                fileURL = try WebInterfaceBundle.resourceFileURL(for: url)
            }
            let data = try Data(contentsOf: fileURL)
            let payload = fileURL.pathExtension.lowercased() == "html" ? Self.addingContentSecurityPolicy(to: data) : data
            let response = URLResponse(
                url: url,
                mimeType: Self.mimeType(for: fileURL.pathExtension),
                expectedContentLength: payload.count,
                textEncodingName: Self.isText(fileURL.pathExtension) ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            if method == "GET" {
                urlSchemeTask.didReceive(payload)
            }
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html"
        case "css": "text/css"
        case "js", "mjs": "text/javascript"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "wasm": "application/wasm"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }

    private static func isText(_ pathExtension: String) -> Bool {
        ["html", "css", "js", "mjs", "json", "map", "svg", "txt"].contains(pathExtension.lowercased())
    }

    private static func addingContentSecurityPolicy(to data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) else { return data }
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: meta, at: head.upperBound)
        } else {
            html.insert(contentsOf: meta, at: html.startIndex)
        }
        return Data(html.utf8)
    }
}
