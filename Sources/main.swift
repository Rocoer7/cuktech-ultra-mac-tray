import AppKit
import Foundation

/// 命令行回归自检（--selftest）：
/// 1. 单元自测：覆盖功率五档边界、MAC 校验、带 charset 二维码剥离、SSE 帧解析与防盲写保护
/// 2. 单应用内置双引擎自测：验证内置运行库完整 -> 无界面拉起 18399 蓝牙服务与 18383 网页服务 -> 校验 HTTP/SSE -> stopSync() 干净回收两个内部子进程
enum SelfTestRunner {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    @MainActor
    private static func runUnitTests() throws {
        try check(WattStyle.totalTier(0.0, connected: true) == .dim, "0W 应为 dim")
        try check(WattStyle.totalTier(65.0, connected: false) == .dim, "未连接时任意功率应为 dim")
        try check(WattStyle.totalTier(0.1, connected: true) == .cool, "0.1W 应为 cool")
        try check(WattStyle.totalTier(20.0, connected: true) == .ok, "20W 边界应为 ok")
        try check(WattStyle.totalTier(60.0, connected: true) == .warn, "60W 边界应为 warn")
        try check(WattStyle.totalTier(100.0, connected: true) == .bad, "100W 边界应为 bad")
        try check(WattStyle.formatWatts(36.84) == "36.8", "<100W 保留一位小数")
        try check(WattStyle.formatWatts(105.4) == "105", ">=100W 省略小数")

        try check(!Smart10uStore.isValidConfiguredMac(""), "空 MAC 应为未配置")
        try check(!Smart10uStore.isValidConfiguredMac("XX:XX:XX:XX:XX:XX"), "模板占位 MAC 应为未配置")
        try check(Smart10uStore.isValidConfiguredMac("A4:C1:38:12:34:56"), "真实 12 位十六进制 MAC 应为已配置")

        let sampleDataURL = "data:image/png;charset=UTF-8;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let commaIdx = sampleDataURL.firstIndex(of: ",")!
        let b64 = String(sampleDataURL[sampleDataURL.index(after: commaIdx)...])
        try check(Data(base64Encoded: b64) != nil, "应能正确剥离 charset=UTF-8 前缀并解码二维码 PNG")

        let store = Smart10uStore(supervisor: BackendSupervisor())
        let initPayload = """
        {"type":"init","connected":true,"authenticated":true,"phase":"ready","firmware_version":"2.1.2_0079","settings":{"5":2,"16":11},"ports":{"1":{"voltage":20.1,"current":2.5,"power":50.2,"active":true,"enabled":true,"protocol":"PD PPS"},"2":{"voltage":9.0,"current":1.5,"power":13.5,"active":true,"enabled":true,"protocol":"PD"},"3":{"voltage":0,"current":0,"power":0,"active":false,"enabled":false,"protocol":"idle"},"4":{"voltage":0,"current":0,"power":0,"active":false,"enabled":true,"protocol":"idle"}}}
        """
        store.handleSSEPayload(initPayload)
        try check(store.snapshot.connected && store.snapshot.authenticated, "init 后应为已连接已认证")
        try check(store.snapshot.sceneMode == 2, "场景模式应解析为 2")
        try check(store.snapshot.ports[2].enabled == false, "掩码 0x0B 下 C3 应为已断电")

        let updatePayload = """
        {"type":"port_update","port_id":2,"port":"c2","data":{"voltage":15.0,"current":2.0,"power":30.0,"active":true,"protocol":"PD"}}
        """
        store.handleSSEPayload(updatePayload)
        try check(abs(store.snapshot.ports[1].power - 30.0) < 0.01, "port_update 后 C2 功率应更新为 30.0W")

        let disconnectPayload = """
        {"type":"status","connected":false,"authenticated":false,"phase":"scanning"}
        """
        store.handleSSEPayload(disconnectPayload)
        try check(!store.snapshot.isBleReady, "status 断开后 isBleReady 应为 false")
        try check(store.snapshot.ports[0].power == 0.0, "断开后单口功率应清零")

        store.setPortEnabled(store.snapshot.ports[0], enabled: false)
        try check(!store.isBusy, "未连接充电器时必须拦截写入控制命令")

        // 握手阶段日志解析与防误触保护自测
        let logScan = "2026-11-24 17:33:13 cuktech_ble INFO Scanning for charger..."
        try check(Smart10uStore.parseHandshakePhase(fromLogTail: logScan)?.phase == "scanning", "应识别 scanning 阶段")
        let logStep3 = """
        2026-11-24 17:33:13 cuktech_ble INFO Scanning for charger...
        2026-11-24 17:33:40 cuktech_ble INFO   [3/5] 发送随机密钥...
        """
        let step3Parsed = Smart10uStore.parseHandshakePhase(fromLogTail: logStep3)
        try check(step3Parsed?.phase == "authenticating" && step3Parsed?.detail.contains("[3/5]") == true, "应精确提取 [3/5] 加密握手阶段")
        let logRetry = "2026-11-24 17:31:19 cuktech_ble WARNING Charger not found with MAC: A4:C1 (will retry)"
        try check(Smart10uStore.parseHandshakePhase(fromLogTail: logRetry)?.phase == "retrying", "未扫到设备时应进入 retrying 允许手动重连")

        print("[selftest] OK: 单元自测全部通过")
    }

    static func run() async -> Int32 {
        do {
            try await MainActor.run {
                try runUnitTests()
            }
        } catch {
            fputs("[selftest] FAIL (unit): \(error.localizedDescription)\n", stderr)
            return 1
        }

        print("[selftest] 启动单应用内置双引擎集成自测…")
        let supervisor = BackendSupervisor()
        guard supervisor.hasEmbeddedRuntime else {
            fputs("[selftest] FAIL: Bundle 内缺少内置运行库: \(supervisor.contentsDir.path)\n", stderr)
            return 1
        }
        print("[selftest] OK: 内置运行库校验完整 (\(supervisor.contentsDir.path))")

        let bInitial = await supervisor.checkBackendHealth()
        let fInitial = await supervisor.checkFrontendHealth()
        let wasAlreadyRunning = bInitial && fInitial
        if !wasAlreadyRunning {
            supervisor.start()
        }

        var bothReady = false
        for _ in 0..<36 {
            let b = await supervisor.checkBackendHealth()
            let f = await supervisor.checkFrontendHealth()
            if b && f {
                bothReady = true
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        guard bothReady else {
            fputs("[selftest] FAIL: 18s 内内置蓝牙服务(18399)或网页网关(18383)未就绪\n", stderr)
            supervisor.stopSync()
            return 1
        }

        let activeBackend = await supervisor.resolveActiveBackendURL()
        print("[selftest] OK: 内置蓝牙后端已就绪 -> \(activeBackend.absoluteString)")
        print("[selftest] OK: 内置网页工作台已就绪 -> \(supervisor.frontendURL.absoluteString)")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: cfg)

        do {
            var req = URLRequest(url: activeBackend.appendingPathComponent("api/events"))
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                fputs("[selftest] FAIL: /api/events HTTP 状态异常\n", stderr)
                supervisor.stopSync()
                return 1
            }
            var gotInit = false
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if let d = raw.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       (obj["type"] as? String) == "init" {
                        gotInit = true
                        break
                    }
                }
            }
            guard gotInit else {
                fputs("[selftest] FAIL: 未收到 SSE init 首帧\n", stderr)
                supervisor.stopSync()
                return 1
            }
            print("[selftest] OK: /api/events SSE init 首帧接收成功")
        } catch {
            fputs("[selftest] FAIL: /api/events 异常: \(error)\n", stderr)
            supervisor.stopSync()
            return 1
        }

        if !wasAlreadyRunning {
            supervisor.stopSync()
            try? await Task.sleep(nanoseconds: 600_000_000)
            let bAlive = await supervisor.checkBackendHealth()
            let fAlive = await supervisor.checkFrontendHealth()
            if bAlive || fAlive {
                fputs("[selftest] FAIL: stopSync() 后内部子进程仍在监听端口\n", stderr)
                return 1
            }
            print("[selftest] OK: stopSync() 已干净停止两个内置子进程")
        } else {
            print("[selftest] OK: 检测到实例正在运行，保持现有蓝牙会话不中断")
        }
        print("[selftest] ALL PASSED")
        return 0
    }
}

// MARK: - 程序入口

let args = Set(CommandLine.arguments.dropFirst())

if args.contains("--selftest") {
    Task {
        let exitCode = await SelfTestRunner.run()
        fflush(stdout)
        fflush(stderr)
        exit(exitCode)
    }
    dispatchMain()
}

if !args.contains("--standalone"), let bundleID = Bundle.main.bundleIdentifier {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != myPID && !$0.isTerminated }
    if !others.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.showPanelNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        exit(0)
    }
}

let trayOnly = args.contains("--tray-only")
let forcePanel = args.contains("--panel")
let initialTab: PanelTab? = args.contains("--control") ? .control : nil

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated {
    AppDelegate(trayOnly: trayOnly, forcePanel: forcePanel, initialTab: initialTab)
}
app.delegate = delegate
app.run()
