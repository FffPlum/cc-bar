import XCTest
import WebKit
@testable import CCBar

@MainActor
final class WebInterfaceBundleTests: XCTestCase {
    private var bundleRoot: URL!

    override func setUp() {
        super.setUp()
        bundleRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: bundleRoot.appendingPathComponent("WebInterface"),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let bundleRoot { try? FileManager.default.removeItem(at: bundleRoot) }
        bundleRoot = nil
        super.tearDown()
    }

    func testResolverRejectsTraversalAndMissingRoot() throws {
        let index = try write("index.html", "<html></html>")
        XCTAssertEqual(
            try WebInterfaceBundle.resourceFileURL(for: WebInterfaceBundle.entryURL, bundleRoot: bundleRoot),
            index.standardizedFileURL.resolvingSymlinksInPath()
        )
        let rejected = [
            "ccbar-ui://app/../secret",
            "ccbar-ui://app/%2E%2E/secret",
            "ccbar-ui://app/assets/%2E%2E/%2E%2E/secret",
            "ccbar-ui://app/assets%2F..%2Fsecret",
            "ccbar-ui://app/assets%5C..%5Csecret",
            "ccbar-ui://app/assets//index.html",
            "https://app/index.html",
            "ccbar-ui://other/index.html"
        ]
        for string in rejected {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertThrowsError(try WebInterfaceBundle.resourceFileURL(for: url, bundleRoot: bundleRoot), string)
        }
        let missingRoot = bundleRoot.appendingPathComponent("missing")
        XCTAssertThrowsError(try WebInterfaceBundle.resourceFileURL(for: WebInterfaceBundle.entryURL, bundleRoot: missingRoot))
    }

    func testResolverRejectsSymlinkEscapeAndSiblingPrefix() throws {
        let sibling = bundleRoot.appendingPathComponent("WebInterface-secret")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let secret = sibling.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let link = bundleRoot.appendingPathComponent("WebInterface/escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let url = try XCTUnwrap(URL(string: "ccbar-ui://app/escape.txt"))
        XCTAssertThrowsError(try WebInterfaceBundle.resourceFileURL(for: url, bundleRoot: bundleRoot)) { error in
            XCTAssertEqual(error as? WebInterfaceResourceError, .outsideRoot)
        }

        let escapingRoot = bundleRoot.appendingPathComponent("escaping-root")
        try FileManager.default.createDirectory(at: escapingRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: escapingRoot.appendingPathComponent("WebInterface"),
            withDestinationURL: sibling
        )
        XCTAssertThrowsError(try WebInterfaceBundle.resourceFileURL(for: WebInterfaceBundle.entryURL, bundleRoot: escapingRoot))
    }

    func testSchemeHandlerUsesFinalPayloadLengthForGETAndHEAD() throws {
        let source = "<html><head></head><body>app</body></html>"
        _ = try write("index.html", source)
        let handler = WebInterfaceSchemeHandler(bundleRoot: bundleRoot)
        let webView = WKWebView(frame: .zero)
        let get = WebInterfaceSchemeTask(url: WebInterfaceBundle.entryURL, method: "GET")
        handler.webView(webView, start: get)
        XCTAssertNil(get.error)
        XCTAssertTrue(get.finished)
        let payload = try XCTUnwrap(get.payloads.first)
        XCTAssertEqual(get.response?.expectedContentLength, Int64(payload.count))
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("Content-Security-Policy"))

        let head = WebInterfaceSchemeTask(url: WebInterfaceBundle.entryURL, method: "HEAD")
        handler.webView(webView, start: head)
        XCTAssertNil(head.error)
        XCTAssertTrue(head.finished)
        XCTAssertTrue(head.payloads.isEmpty)
        XCTAssertEqual(head.response?.expectedContentLength, Int64(payload.count))
    }

    func testUnknownMIMETypeAndMainDocumentRule() throws {
        let data = Data([0, 1, 2, 3])
        let file = bundleRoot.appendingPathComponent("WebInterface/payload.unknown")
        try data.write(to: file)
        let url = try XCTUnwrap(URL(string: "ccbar-ui://app/payload.unknown"))
        let task = WebInterfaceSchemeTask(url: url, method: "GET")
        WebInterfaceSchemeHandler(bundleRoot: bundleRoot).webView(WKWebView(frame: .zero), start: task)
        XCTAssertNil(task.error)
        XCTAssertEqual(task.response?.mimeType, "application/octet-stream")
        XCTAssertEqual(task.payloads, [data])

        XCTAssertTrue(WebInterfaceBundle.isMainDocumentURL(WebInterfaceBundle.entryURL))
        XCTAssertTrue(WebInterfaceBundle.isMainDocumentURL(try XCTUnwrap(URL(string: "ccbar-ui://app/index.html#/stats"))))
        XCTAssertFalse(WebInterfaceBundle.isMainDocumentURL(url))
        XCTAssertTrue(MacOSWebKitTransport.isTrusted(
            mainFrame: true,
            url: WebInterfaceBundle.entryURL,
            trustedURL: WebInterfaceBundle.entryURL
        ))
        XCTAssertFalse(MacOSWebKitTransport.isTrusted(
            mainFrame: true,
            url: try XCTUnwrap(URL(string: "ccbar-ui://evil/index.html")),
            trustedURL: WebInterfaceBundle.entryURL
        ))
    }

    private func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = bundleRoot.appendingPathComponent("WebInterface/\(relativePath)")
        try Data(contents.utf8).write(to: url)
        return url
    }
}

@MainActor
private final class WebInterfaceSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: URLResponse?
    private(set) var payloads: [Data] = []
    private(set) var finished = false
    private(set) var error: (any Error)?

    init(url: URL, method: String) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        self.response = response
    }

    func didReceive(_ data: Data) {
        payloads.append(data)
    }

    func didFinish() {
        finished = true
    }

    func didFailWithError(_ error: any Error) {
        self.error = error
    }
}
