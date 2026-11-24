import Darwin
import Foundation

/// 单应用内置双引擎守护器：
/// 直接在当前 .app Bundle 内无界面（Headless）拉起并守护：
/// 1. 蓝牙后端服务：Contents/MacOS/CUKTECH Studio -m cuktech_server --host 127.0.0.1 --api-only (端口 18399)
/// 2. 网页工作台服务：Contents/Frameworks/desktop/node Contents/Resources/desktop/gateway.mjs (端口 18383)
/// 不启动原版 Studio 的菜单栏外壳，因此顶部状态栏永远只有 1 个图标；退出本应用时同步停止内部双子进程。
final class BackendSupervisor {
    let contentsDir: URL
    let frontendPort: Int = 18383
    let managedBackendPort: Int = 18399
    let frontendURL: URL
    let defaultBackendURL: URL
    let studioDataDir: URL

    private let lock = NSLock()
    private var cachedBackendURL: URL
    private var backendProcess: Process?
    private var frontendProcess: Process?
    private var backendLogHandle: FileHandle?
    private var frontendLogHandle: FileHandle?
    private var isStopping = false
    private var monitorTask: Task<Void, Never>?

    private let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 2.5
        cfg.timeoutIntervalForResource = 3.0
        return URLSession(configuration: cfg)
    }()

    init() {
        self.contentsDir = Self.resolveBundleContentsDir()
        self.frontendURL = URL(string: "http://127.0.0.1:\(frontendPort)")!
        self.defaultBackendURL = URL(string: "http://127.0.0.1:\(managedBackendPort)")!
        self.cachedBackendURL = self.defaultBackendURL
        self.studioDataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CUKTECH Studio")
    }

    private static func resolveBundleContentsDir() -> URL {
        // 可执行文件位于 <App>.app/Contents/MacOS/CuktechStudioTray
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return execURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private var engineExecutableURL: URL {
        contentsDir.appendingPathComponent("MacOS/CUKTECH Studio")
    }

    private var nodeExecutableURL: URL {
        contentsDir.appendingPathComponent("Frameworks/desktop/node")
    }

    private var gatewayScriptURL: URL {
        contentsDir.appendingPathComponent("Resources/desktop/gateway.mjs")
    }

    var hasEmbeddedRuntime: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: engineExecutableURL.path)
            && fm.isExecutableFile(atPath: nodeExecutableURL.path)
            && fm.fileExists(atPath: gatewayScriptURL.path)
    }

    var activeBackendURL: URL {
        lock.withLock { cachedBackendURL }
    }

    var logFileURL: URL {
        let primary = studioDataDir.appendingPathComponent("logs/backend.log")
        if FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }
        return studioDataDir.appendingPathComponent("logs/backend-console.log")
    }

    // MARK: - 生命周期控制

    func start() {
        lock.withLock {
            isStopping = false
            if monitorTask == nil {
                monitorTask = Task.detached(priority: .utility) { [weak self] in
                    await self?.superviseLoop()
                }
            }
        }
    }

    @discardableResult
    func resolveActiveBackendURL() async -> URL {
        let metaURL = frontendURL.appendingPathComponent("__dev/backend")
        var req = URLRequest(url: metaURL)
        req.setValue("127.0.0.1:\(frontendPort)", forHTTPHeaderField: "Host")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, resp) = try await probeSession.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let activeStr = dict["active"] as? String,
               let url = URL(string: activeStr) {
                lock.withLock {
                    cachedBackendURL = url
                }
                return url
            }
        } catch {
            // 网关未就绪时保留默认本地 18399 后端
        }
        return activeBackendURL
    }

    func checkFrontendHealth() async -> Bool {
        let url = frontendURL.appendingPathComponent("healthz")
        do {
            let (_, resp) = try await probeSession.data(from: url)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {
            return false
        }
        return false
    }

    func checkBackendHealth() async -> Bool {
        let backend = await resolveActiveBackendURL()
        let url = backend.appendingPathComponent("api/health")
        do {
            let (_, resp) = try await probeSession.data(from: url)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {
            return false
        }
        return false
    }

    func restartServices() async {
        stopProcessesSync()
        try? await Task.sleep(nanoseconds: 700_000_000)
        launchBackendIfNeeded()
        launchFrontendIfNeeded()
    }

    func stopSync() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            isStopping = true
            let t = monitorTask
            monitorTask = nil
            return t
        }
        task?.cancel()
        stopProcessesSync()
    }

    // MARK: - 守护循环与内部子进程拉起

    private func superviseLoop() async {
        while !Task.isCancelled {
            if isLockedStopping() { break }

            let backendOK = await checkLocalManagedBackendHealth()
            if !backendOK {
                launchBackendIfNeeded()
            }

            let frontendOK = await checkFrontendHealth()
            if !frontendOK {
                launchFrontendIfNeeded()
            }

            if !backendOK || !frontendOK {
                for _ in 0..<24 {
                    if Task.isCancelled || isLockedStopping() { return }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let b = await checkLocalManagedBackendHealth()
                    let f = await checkFrontendHealth()
                    if b && f { break }
                }
            }

            try? await Task.sleep(nanoseconds: 3_500_000_000)
        }
    }

    private func checkLocalManagedBackendHealth() async -> Bool {
        let url = defaultBackendURL.appendingPathComponent("api/health")
        do {
            let (_, resp) = try await probeSession.data(from: url)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {
            return false
        }
        return false
    }

    private func isLockedStopping() -> Bool {
        lock.withLock { isStopping }
    }

    private func ensureDataDirectories() -> URL {
        let logsDir = studioDataDir.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir
    }

    private func openAppendHandle(at fileURL: URL) -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        return handle
    }

    private func launchBackendIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if isStopping { return }
        if let proc = backendProcess, proc.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: engineExecutableURL.path) else { return }

        let logsDir = ensureDataDirectories()
        let consoleLog = logsDir.appendingPathComponent("backend-console.log")
        let handle = openAppendHandle(at: consoleLog)
        self.backendLogHandle = handle

        let proc = Process()
        proc.executableURL = engineExecutableURL
        // 不传 --standby，使内置蓝牙服务启动后直接自动连接已绑定的充电器
        proc.arguments = ["-m", "cuktech_server", "--host", "127.0.0.1", "--api-only"]
        proc.currentDirectoryURL = studioDataDir

        var env = ProcessInfo.processInfo.environment
        env["CUKTECH_CONFIG_PATH"] = studioDataDir.appendingPathComponent("config.yaml").path
        env["CUKTECH_HISTORY_DB_PATH"] = studioDataDir.appendingPathComponent("history.db").path
        env["CUKTECH_LOG_FILE"] = logsDir.appendingPathComponent("backend.log").path
        env["CUKTECH_LOG_STREAM"] = "1"
        env["CUKTECH_SERVER_PORT"] = "\(managedBackendPort)"
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_PROXY"] = "127.0.0.1,localhost"
        env["no_proxy"] = "127.0.0.1,localhost"
        proc.environment = env

        if let handle {
            proc.standardOutput = handle
            proc.standardError = handle
        }

        try? proc.run()
        self.backendProcess = proc
    }

    private func launchFrontendIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if isStopping { return }
        if let proc = frontendProcess, proc.isRunning { return }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: nodeExecutableURL.path),
              fm.fileExists(atPath: gatewayScriptURL.path) else { return }

        let logsDir = ensureDataDirectories()
        let consoleLog = logsDir.appendingPathComponent("frontend-console.log")
        let handle = openAppendHandle(at: consoleLog)
        self.frontendLogHandle = handle

        let proc = Process()
        proc.executableURL = nodeExecutableURL
        proc.arguments = [gatewayScriptURL.path]
        proc.currentDirectoryURL = gatewayScriptURL.deletingLastPathComponent()

        var env = ProcessInfo.processInfo.environment
        env["CUKTECH_DESKTOP_DATA"] = studioDataDir.path
        env["CUKTECH_FRONTEND_PORT"] = "\(frontendPort)"
        env["CUKTECH_MANAGED_BACKEND_PORT"] = "\(managedBackendPort)"
        env["NO_PROXY"] = "127.0.0.1,localhost"
        env["no_proxy"] = "127.0.0.1,localhost"
        proc.environment = env

        if let handle {
            proc.standardOutput = handle
            proc.standardError = handle
        }

        try? proc.run()
        self.frontendProcess = proc
    }

    private func stopProcessesSync() {
        let (bProc, fProc, bLog, fLog) = lock.withLock { () -> (Process?, Process?, FileHandle?, FileHandle?) in
            let bp = backendProcess
            let fp = frontendProcess
            let bl = backendLogHandle
            let fl = frontendLogHandle
            backendProcess = nil
            frontendProcess = nil
            backendLogHandle = nil
            frontendLogHandle = nil
            return (bp, fp, bl, fl)
        }

        let procs = [fProc, bProc].compactMap { $0 }.filter { $0.isRunning }
        for p in procs {
            p.terminate()
        }

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if procs.allSatisfy({ !$0.isRunning }) { break }
            usleep(80_000)
        }

        for p in procs where p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }

        // 兜底回收任何残留的内置子进程（例如执行过自重启的 cuktech_server）
        terminateOrphanSubprocesses()

        try? fLog?.close()
        try? bLog?.close()
    }

    private func terminateOrphanSubprocesses() {
        let patterns = [
            engineExecutableURL.path,
            gatewayScriptURL.path,
        ]
        var pids = Set<pid_t>()
        let myPID = getpid()

        for pat in patterns {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", pat]
            let pipe = Pipe()
            pgrep.standardOutput = pipe
            pgrep.standardError = FileHandle.nullDevice
            if (try? pgrep.run()) != nil {
                pgrep.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let out = String(data: data, encoding: .utf8) {
                    for line in out.split(whereSeparator: \.isNewline) {
                        if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)), pid > 1, pid != myPID {
                            pids.insert(pid)
                        }
                    }
                }
            }
        }

        guard !pids.isEmpty else { return }
        for pid in pids {
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return }
            usleep(80_000)
        }
        for pid in pids where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }
}
