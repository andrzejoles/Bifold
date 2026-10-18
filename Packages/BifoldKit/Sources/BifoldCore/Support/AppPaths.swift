import Foundation

/// Położenie plików aplikacji w `~/Library/Application Support/<nazwa>`.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Katalog dla nazwy aplikacji (z `Info.plist`, patrz `Config/Brand.xcconfig`).
    /// `BIFOLD_DATA_DIR` zastępuje katalog danych (próby bez dotykania prawdziwych danych, jak
    /// `CANTATE_DATA_DIR` w CantatePresenter).
    public static func standard(appName: String) -> AppPaths {
        if let dir = ProcessInfo.processInfo.environment["BIFOLD_DATA_DIR"], dir.hasPrefix("/") {
            return AppPaths(root: URL(filePath: dir, directoryHint: .isDirectory))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appending(path: appName, directoryHint: .isDirectory))
    }

    public var settings: URL { root.appending(path: "settings.json") }
    public var session: URL { root.appending(path: "session.json") }
    public var colorRules: URL { root.appending(path: "color-rules.json") }
    public var journal: URL { root.appending(path: "journal/operations.jsonl") }
    public var selections: URL { root.appending(path: "selections", directoryHint: .isDirectory) }
    public var agentLogs: URL { root.appending(path: "agent-logs", directoryHint: .isDirectory) }
    public var run: URL { root.appending(path: "run", directoryHint: .isDirectory) }

    public func ensureExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}
