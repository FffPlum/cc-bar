import AppKit
import Foundation

/// Finds the real installed `.app` icon for a `ServiceBrand`.
///
/// Two lookup stages:
/// 1. Bundle-ID lookup — the URL must have an exact allowed `.app` filename and its on-disk
///    `CFBundleIdentifier` must still be one of the candidate bundle IDs.
/// 2. Name fallback — only `/Applications` and `~/Applications` (the default directories); when the
///    candidate declares bundle IDs the `.app`'s `Info.plist` bundle ID must match one of them,
///    otherwise the exact app name is sufficient.
///
/// The Claude Code CLI's `claude-cli://` URL handler is a separate stub bundle
/// (`com.anthropic.claude-code-url-handler`, `Claude Code URL Handler.app`) and is never accepted,
/// even if LaunchServices reports it while resolving the desktop bundle ID.
enum InstalledAppIconLocator {
    static let defaultApplicationURLForBundleID: (String) -> URL? = { bundleID in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var defaultApplicationDirectories: [URL] {
        var directories: [URL] = []
        let fileManager = FileManager.default
        if let local = fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first {
            directories.append(local)
        }
        if let user = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            directories.append(user)
        }
        return directories
    }

    private static let rejectedBundleIdentifiers: Set<String> = ["com.anthropic.claude-code-url-handler"]
    private static let rejectedAppNames: Set<String> = ["Claude Code URL Handler.app"]
    private static let imageCache = NSCache<NSString, NSImage>()

    /// Installed app icon, or `nil` when no valid app is found. Transparent outer margins and faint system shadows are
    /// removed once and cached so desktop icons have the same visible bounds as bundled favicons.
    static func image(for brand: ServiceBrand) -> NSImage? {
        guard let url = applicationURL(for: brand) else { return nil }
        if let cached = imageCache.object(forKey: url.path as NSString) { return cached }
        let image = normalizedAppIcon(NSWorkspace.shared.icon(forFile: url.path))
        imageCache.setObject(image, forKey: url.path as NSString)
        return image
    }

    static func normalizedAppIcon(_ image: NSImage) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            image.isTemplate = false
            return image
        }
        let bitmap = NSBitmapImageRep(cgImage: source)
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent, alpha > 0.5 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0, maxY >= 0,
              minX > 0 || minY > 0 || maxX < bitmap.pixelsWide - 1 || maxY < bitmap.pixelsHigh - 1,
              let cropped = source.cropping(to: CGRect(
                x: minX,
                y: minY,
                width: maxX - minX + 1,
                height: maxY - minY + 1
              )) else {
            image.isTemplate = false
            return image
        }
        let normalized = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        normalized.isTemplate = false
        return normalized
    }

    /// Production convenience that uses the default bundle-ID resolver and application directories.
    static func applicationURL(for brand: ServiceBrand) -> URL? {
        applicationURL(
            for: brand,
            applicationURLForBundleID: defaultApplicationURLForBundleID,
            applicationDirectories: defaultApplicationDirectories
        )
    }

    /// Testable seam. `applicationURLForBundleID` resolves a candidate bundle ID to an app URL;
    /// `applicationDirectories` is the search space for the name fallback.
    static func applicationURL(
        for brand: ServiceBrand,
        applicationURLForBundleID: (String) -> URL? = defaultApplicationURLForBundleID,
        applicationDirectories: [URL] = defaultApplicationDirectories
    ) -> URL? {
        guard let candidate = brand.installedAppCandidate else { return nil }

        // Bundle-ID lookup: exact filename + the resolved bundle still carries a candidate ID.
        for bundleID in candidate.bundleIdentifiers {
            guard let url = applicationURLForBundleID(bundleID), !isRejected(url) else { continue }
            guard candidate.appNames.contains(url.lastPathComponent) else { continue }
            guard let actualID = bundleIdentifier(at: url),
                  candidate.bundleIdentifiers.contains(actualID) else { continue }
            return url
        }

        // Name fallback: default application directories only. Empty candidate IDs means the
        // exact `.app` name is sufficient; otherwise validate the Info.plist bundle ID.
        for directory in applicationDirectories {
            for appName in candidate.appNames {
                let url = directory.appendingPathComponent(appName)
                guard isExistingDirectory(url), !isRejected(url) else { continue }
                if candidate.bundleIdentifiers.isEmpty { return url }
                guard let actualID = bundleIdentifier(at: url),
                      candidate.bundleIdentifiers.contains(actualID) else { continue }
                return url
            }
        }

        return nil
    }

    private static func isRejected(_ url: URL) -> Bool {
        if rejectedAppNames.contains(url.lastPathComponent) { return true }
        if let bundleID = bundleIdentifier(at: url), rejectedBundleIdentifiers.contains(bundleID) {
            return true
        }
        return false
    }

    private static func bundleIdentifier(at appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
