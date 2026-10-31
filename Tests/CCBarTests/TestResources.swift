import Foundation

nonisolated enum TestResources {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        Bundle(for: TestBundleAnchor.self)
        #endif
    }
}

private final class TestBundleAnchor {}
