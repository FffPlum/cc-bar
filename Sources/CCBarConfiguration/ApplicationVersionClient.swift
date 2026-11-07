import Foundation

/// Reads public release metadata; it never reads application credentials or invokes a CLI.
public struct ApplicationVersionClient: Sendable {
    private let session: URLSession
    private static let maximumResponseBytes = 1_048_576

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalidSource, invalidResponse, httpStatus(Int), responseTooLarge, missingVersion

        public var errorDescription: String? {
            switch self {
            case .invalidSource: "The release source is not supported."
            case .invalidResponse: "The release service returned an invalid response."
            case .httpStatus(let status): "The release service returned HTTP \(status)."
            case .responseTooLarge: "The release response exceeded the size limit."
            case .missingVersion: "The release service did not provide a recognized version."
            }
        }
    }

    /// The detected owner takes priority over the catalog's default installation method.
    public static func source(for definition: ManagedApplicationDefinition,
                              installation: ApplicationInstallation) -> ApplicationReleaseSource? {
        guard installation.catalogID == definition.id else { return nil }
        switch installation.source {
        case .npm:
            guard let package = installation.package ?? definition.npmPackage else { return nil }
            let accepted = [definition.npmPackage, definition.id == "pi" ? "@badlogic/pi-coding-agent" : nil]
            guard accepted.contains(where: { $0 == package }) else { return nil }
            return .npm(package)
        case .uv, .pipx:
            guard let package = installation.package ?? definition.pythonPackage,
                  package == definition.pythonPackage else { return nil }
            return .pypi(package)
        case .homebrew:
            guard let package = installation.package ?? definition.brewPackage else { return nil }
            guard package == definition.brewPackage || (definition.id == "claude" && package == "claude-code@latest") else {
                return nil
            }
            // A binary in Cellar is a formula even when a cask is the recommended new installation.
            let cask = installation.resolvedPath.contains("/Caskroom/") ? true
                : installation.resolvedPath.contains("/Cellar/") ? false : definition.brewCask
            return .homebrew(package, cask: cask)
        case .native, .bundle:
            return definition.releaseSource
        case .unknown:
            return nil
        }
    }

    public func latest(for source: ApplicationReleaseSource) async throws -> String {
        let url = try Self.url(for: source)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CCBar", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "https", response.url?.host == url.host else {
            throw Failure.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else { throw Failure.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw Failure.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else { throw Failure.responseTooLarge }
            data.append(byte)
        }
        return try Self.version(in: data, source: source)
    }

    /// An unrecognized version is not evidence that an installation is up to date.
    public static func compare(installed: String, latest: String) -> ComparisonResult? {
        guard let installed = SemanticVersion(installed), let latest = SemanticVersion(latest) else { return nil }
        return installed.compare(to: latest)
    }

    static func url(for source: ApplicationReleaseSource) throws -> URL {
        let address: String
        switch source {
        case .npm(let package):
            guard package.range(of: #"^(?:@[A-Za-z0-9_-]+/)?[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                                options: .regularExpression) != nil else { throw Failure.invalidSource }
            let encoded = package.replacingOccurrences(of: "/", with: "%2F")
            address = "https://registry.npmjs.org/-/package/\(encoded)/dist-tags"
        case .pypi(let package):
            guard validComponent(package) else { throw Failure.invalidSource }
            address = "https://pypi.org/pypi/\(package)/json"
        case .github(let repository):
            let pieces = repository.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces.allSatisfy({ validComponent(String($0)) }) else {
                throw Failure.invalidSource
            }
            address = "https://api.github.com/repos/\(repository)/releases/latest"
        case .homebrew(let package, let cask):
            guard validComponent(package, allowAt: true) else { throw Failure.invalidSource }
            address = "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(package).json"
        case .manifest(let manifest):
            let base = ManagedApplicationCatalog.antigravityManifestBaseURL
            guard [base + "darwin_arm64.json", base + "darwin_amd64.json"].contains(manifest) else {
                throw Failure.invalidSource
            }
            address = manifest
        }
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil else {
            throw Failure.invalidSource
        }
        return url
    }

    static func version(in data: Data, source: ApplicationReleaseSource) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        let candidate: String?
        switch source {
        case .npm:
            candidate = object["latest"] as? String
        case .pypi:
            candidate = (object["info"] as? [String: Any])?["version"] as? String
        case .manifest:
            candidate = object["version"] as? String
        case .homebrew(_, let cask):
            candidate = cask
                ? (object["version"] as? String)?.components(separatedBy: ",").first
                : (object["versions"] as? [String: Any])?["stable"] as? String
        case .github(let repository):
            // Hermes release tags can be calendar dates; its release name contains the CLI version.
            let fields = repository.lowercased() == "nousresearch/hermes-agent"
                ? [object["name"] as? String, object["tag_name"] as? String]
                : [object["tag_name"] as? String, object["name"] as? String]
            candidate = fields.compactMap { $0 }.compactMap { value in
                guard let version = semanticVersionInReleaseTitle(value) else { return nil }
                if repository.lowercased() == "nousresearch/hermes-agent", version.major >= 1000 { return nil }
                return version.text
            }.first
        }
        guard let candidate, let version = SemanticVersion(candidate) else { throw Failure.missingVersion }
        return version.text
    }

    private static func validComponent(_ value: String, allowAt: Bool = false) -> Bool {
        let pattern = allowAt ? #"^[A-Za-z0-9][A-Za-z0-9._@-]*$"# : #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func semanticVersionInReleaseTitle(_ title: String) -> SemanticVersion? {
        if let version = SemanticVersion(title) { return version }
        guard let expression = try? NSRegularExpression(pattern: #"(?<![\w.])v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?(?![\w.])"#) else { return nil }
        let matches = expression.matches(in: title, range: NSRange(title.startIndex..., in: title))
        // Ambiguous release titles should not silently select an unrelated dependency's version.
        guard matches.count == 1, let range = Range(matches[0].range, in: title) else { return nil }
        return SemanticVersion(String(title[range]))
    }
}

private struct SemanticVersion {
    let text: String
    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    let prerelease: [String]

    init?(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)) else {
            return nil
        }
        func part(_ index: Int) -> String? {
            Range(match.range(at: index), in: version).map { String(version[$0]) }
        }
        guard let major = part(1).flatMap(UInt64.init), let minor = part(2).flatMap(UInt64.init),
              let patch = part(3).flatMap(UInt64.init) else { return nil }
        let prerelease = part(4)?.components(separatedBy: ".") ?? []
        guard prerelease.allSatisfy({ identifier in
            !identifier.allSatisfy(\.isNumber) || identifier.count == 1 || !identifier.hasPrefix("0")
        }) else { return nil }
        self.text = version; self.major = major; self.minor = minor; self.patch = patch
        self.prerelease = prerelease
    }

    func compare(to other: Self) -> ComparisonResult {
        for (left, right) in zip([major, minor, patch], [other.major, other.minor, other.patch]) {
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        if prerelease.isEmpty && !other.prerelease.isEmpty { return .orderedDescending }
        if !prerelease.isEmpty && other.prerelease.isEmpty { return .orderedAscending }
        for (left, right) in zip(prerelease, other.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber), rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric && rightNumeric {
                // Compare arbitrary-size numeric identifiers without overflowing an integer.
                if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
                return left < right ? .orderedAscending : .orderedDescending
            }
            if leftNumeric != rightNumeric { return leftNumeric ? .orderedAscending : .orderedDescending }
            return left < right ? .orderedAscending : .orderedDescending
        }
        if prerelease.count == other.prerelease.count { return .orderedSame }
        return prerelease.count < other.prerelease.count ? .orderedAscending : .orderedDescending
    }
}
