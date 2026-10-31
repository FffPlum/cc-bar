import Foundation

/// 一个 Git worktree 与其主仓库的对应关系。
nonisolated struct ProjectWorktreeLink: Sendable, Equatable {
    /// 主仓库根目录（规范路径）。
    var mainPath: String
    /// worktree 当前检出的分支；读不到（分离 HEAD、文件缺失）时为 nil。
    var branch: String?
}

/// 按项目路径识别 Git worktree 并找到主仓库，供统计页把 worktree 用量计入主仓库。
///
/// 只读文件系统，不改任何存储：worktree 根目录下的 `.git` 是一个文件，内容为
/// `gitdir: <主仓库>/.git/worktrees/<名称>`；该目录下的 `commondir` 指回主仓库的 `.git`。
/// 与 `ConversationProjectResolver` 使用同一套隐私分级：worktree、gitdir、主仓库三处路径
/// 任何一处落在家目录之外或 TCC 保护目录内都不读取，按独立项目显示，不会触发系统授权。
///
/// 结果按路径缓存（包括「不是 worktree」），每个唯一路径只检查一次。
nonisolated final class ProjectWorktreeResolver {
    private let home: String
    private let fm = FileManager.default
    private var linkCache: [String: ProjectWorktreeLink?] = [:]
    private var gitCache: [String: Bool] = [:]

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) {
        self.home = home
    }

    /// `path` 是 worktree 时返回主仓库；普通仓库、非 Git 目录、不可读或受保护路径返回 nil。
    func link(forProjectPath path: String) -> ProjectWorktreeLink? {
        if let cached = linkCache[path] { return cached }
        let result = resolveLink(path)
        linkCache[path] = result
        return result
    }

    /// 路径下是否有 `.git`（目录或 worktree 的 `.git` 文件）。受保护路径返回 nil（未知）。
    func isGitRepository(_ path: String) -> Bool? {
        guard allowed(path) else { return nil }
        if let cached = gitCache[path] { return cached }
        let result = fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
        gitCache[path] = result
        return result
    }

    /// 普通仓库（`.git` 为目录）当前检出的分支；受保护路径、分离 HEAD 或读不到时返回 nil。
    func currentBranch(ofRepository path: String) -> String? {
        guard allowed(path) else { return nil }
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return Self.branch(inGitDir: dotGit)
    }

    private func allowed(_ path: String) -> Bool {
        ConversationProjectResolver.allowsFileSystemCheck(standardizedPath: path, home: home)
    }

    private func resolveLink(_ path: String) -> ProjectWorktreeLink? {
        guard allowed(path) else { return nil }
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue,
              let content = Self.readSmallText(dotGit)
        else { return nil }

        guard let line = content.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }
        let rawGitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !rawGitDir.isEmpty else { return nil }
        let gitDir = Self.standardize(rawGitDir, relativeTo: path)
        guard allowed(gitDir) else { return nil }

        let commonDir: String
        if let rawCommon = Self.readSmallText((gitDir as NSString).appendingPathComponent("commondir"))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !rawCommon.isEmpty {
            commonDir = Self.standardize(rawCommon, relativeTo: gitDir)
        } else if let range = gitDir.range(of: "/.git/worktrees/") {
            commonDir = String(gitDir[..<range.lowerBound]) + "/.git"
        } else {
            return nil
        }
        // bare 仓库没有工作区，不作为主仓库。
        guard (commonDir as NSString).lastPathComponent == ".git" else { return nil }
        let mainPath = (commonDir as NSString).deletingLastPathComponent
        guard mainPath != path, allowed(mainPath), fm.fileExists(atPath: mainPath) else { return nil }

        return ProjectWorktreeLink(mainPath: mainPath, branch: Self.branch(inGitDir: gitDir))
    }

    private static func branch(inGitDir gitDir: String) -> String? {
        guard let head = readSmallText((gitDir as NSString).appendingPathComponent("HEAD"))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              head.hasPrefix("ref: ")
        else { return nil }
        let ref = head.dropFirst("ref: ".count)
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : String(ref)
    }

    private static func standardize(_ raw: String, relativeTo base: String) -> String {
        let absolute = raw.hasPrefix("/") ? raw : (base as NSString).appendingPathComponent(raw)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    /// `.git` / `commondir` / `HEAD` 都只有一两行；超过 4KB 视为异常，不读取。
    private static func readSmallText(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 4096,
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
