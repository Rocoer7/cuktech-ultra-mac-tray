import Foundation

/// 管理当前用户的「随 macOS 登录自动启动」（~/Library/LaunchAgents/local.cuktechstudio.tray.plist）
enum LaunchAgentHelper {
    private static let label = "local.cuktechstudio.tray"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let fm = FileManager.default
        if !enabled {
            if fm.fileExists(atPath: plistURL.path) {
                try? fm.removeItem(at: plistURL)
            }
            return true
        }

        let execPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let launchAgentsDir = plistURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            let plistDict: [String: Any] = [
                "Label": label,
                "ProgramArguments": [execPath, "--tray-only"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plistDict,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
