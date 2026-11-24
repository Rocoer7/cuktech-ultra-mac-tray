import AppKit
import Combine
import Foundation

/// 状态栏与三页签面板的数据与控制中心（对接 CUKTECH Studio）：
/// - 自动同步 Studio 网关当前选中的活跃后端地址（本地 18399 或局域网后端）
/// - 订阅 /api/events SSE 实时流，支持多台充电器切换、单口断电 (/api/port) 与充电模式 (/api/set)
@MainActor
final class Smart10uStore: ObservableObject {
    @Published private(set) var snapshot = ChargerSnapshot()
    @Published var selectedTab: PanelTab = .read
    @Published var isBusy: Bool = false
    @Published var feedbackMessage: String = ""
    @Published var feedbackIsError: Bool = false
    @Published var pairState: XiaomiPairState = .hidden
    @Published var pairRegion: String = "cn"
    @Published var pairError: String = ""
    @Published var isPinned: Bool {
        didSet {
            UserDefaults.standard.set(isPinned, forKey: Self.pinnedKey)
            onPinChanged?(isPinned)
        }
    }

    let supervisor: BackendSupervisor
    var onSnapshotChanged: ((ChargerSnapshot) -> Void)?
    var onPinChanged: ((Bool) -> Void)?

    private static let pinnedKey = "CuktechStudioTray.PanelPinned"

    private let apiSession: URLSession
    private let sseSession: URLSession
    private var sseTask: Task<Void, Never>?
    private var pollFallbackTask: Task<Void, Never>?
    private var handshakeWatchTask: Task<Void, Never>?
    private var clearFeedbackTask: Task<Void, Never>?
    private var qrPollTask: Task<Void, Never>?

    init(supervisor: BackendSupervisor) {
        self.supervisor = supervisor
        self.isPinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)

        let apiCfg = URLSessionConfiguration.ephemeral
        apiCfg.connectionProxyDictionary = [:]
        apiCfg.timeoutIntervalForRequest = 12.0
        apiCfg.timeoutIntervalForResource = 15.0
        self.apiSession = URLSession(configuration: apiCfg)

        let sseCfg = URLSessionConfiguration.ephemeral
        sseCfg.connectionProxyDictionary = [:]
        sseCfg.timeoutIntervalForRequest = 300.0
        sseCfg.timeoutIntervalForResource = 0
        self.sseSession = URLSession(configuration: sseCfg)

        self.snapshot.studioInstalled = supervisor.hasEmbeddedRuntime
    }

    // MARK: - 启动与关闭

    func start() {
        snapshot.studioInstalled = supervisor.hasEmbeddedRuntime
        supervisor.start()
        guard sseTask == nil else { return }

        sseTask = Task { [weak self] in
            await self?.runSSELoop()
        }

        // 未连上期间每秒轻量追踪本地 backend.log 末尾的真实握手阶段；连上后零文件读取开销
        handshakeWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { break }
                if self.snapshot.backendReady && self.snapshot.configured && !self.snapshot.isBleReady {
                    self.syncHandshakePhaseFromLog()
                }
            }
        }

        // 定期同步网关活跃后端切换与扫码绑定状态
        pollFallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { break }
                let prevBackend = self.supervisor.activeBackendURL
                let nowBackend = await self.supervisor.resolveActiveBackendURL()
                if prevBackend != nowBackend {
                    // 用户在 Studio 工作台切换了后端，重连 SSE
                    self.restartSSEConnection()
                    continue
                }
                if !self.snapshot.sseConnected {
                    await self.refreshConfigAndStatus()
                } else if !self.snapshot.configured {
                    await self.refreshDevicesAndConfig()
                }
            }
        }
    }

    func shutdown() {
        sseTask?.cancel()
        sseTask = nil
        pollFallbackTask?.cancel()
        pollFallbackTask = nil
        handshakeWatchTask?.cancel()
        handshakeWatchTask = nil
        qrPollTask?.cancel()
        qrPollTask = nil
        clearFeedbackTask?.cancel()
        supervisor.stopSync()
    }

    private func restartSSEConnection() {
        sseTask?.cancel()
        sseTask = Task { [weak self] in
            await self?.runSSELoop()
        }
    }

    // MARK: - 网页工作台与日志入口

    var workbenchURL: URL { supervisor.frontendURL }

    func openDashboard() {
        NSWorkspace.shared.open(workbenchURL)
    }

    func openConfigPage() {
        startXiaomiPairing()
    }

    // MARK: - 内置小米云扫码绑定（绕过 Studio 前端旧域名白名单限制，直写 Studio 后端配置）

    func startXiaomiPairing() {
        qrPollTask?.cancel()
        pairError = ""
        pairState = .loadingQR

        let region = pairRegion
        Task {
            _ = await supervisor.resolveActiveBackendURL()
            let resp = await postRawJSON(path: "api/xiaomi/login", body: ["server": region], timeout: 30.0)
            guard let resp, Self.asBool(resp["ok"]) == true,
                  let sessionID = resp["session_id"] as? String, !sessionID.isEmpty else {
                pairState = .hidden
                let msg = (resp?["error"] as? String) ?? "获取登录二维码失败，请确认网络畅通"
                showFeedback(msg, isError: true)
                return
            }

            let rawQR = (resp["qr_image"] as? String) ?? ""
            let base64Part: String
            if let commaIdx = rawQR.firstIndex(of: ",") {
                base64Part = String(rawQR[rawQR.index(after: commaIdx)...])
            } else {
                base64Part = rawQR
            }
            let loginURL = (resp["login_url"] as? String) ?? ""
            pairState = .showingQR(sessionID: sessionID, qrBase64: base64Part, loginURL: loginURL)
            beginQRPolling(sessionID: sessionID)
        }
    }

    func cancelXiaomiPairing() {
        qrPollTask?.cancel()
        qrPollTask = nil
        pairError = ""
        pairState = .hidden
    }

    func checkXiaomiQRNow() {
        guard case let .showingQR(sessionID, _, _) = pairState else { return }
        Task {
            await pollXiaomiOnce(sessionID: sessionID, manualTrigger: true)
        }
    }

    private func beginQRPolling(sessionID: String) {
        qrPollTask?.cancel()
        qrPollTask = Task { [weak self] in
            for _ in 0..<45 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                guard case let .showingQR(curID, _, _) = self.pairState, curID == sessionID else { return }
                let done = await self.pollXiaomiOnce(sessionID: sessionID, manualTrigger: false)
                if done { return }
            }
            await MainActor.run { [weak self] in
                self?.pairError = "二维码已超时，请点击「刷新二维码」重试"
            }
        }
    }

    @discardableResult
    private func pollXiaomiOnce(sessionID: String, manualTrigger: Bool) async -> Bool {
        guard let resp = await postRawJSON(
            path: "api/xiaomi/qr/complete",
            body: ["session_id": sessionID],
            timeout: 25.0
        ) else {
            return false
        }

        if Self.asBool(resp["ok"]) == true {
            qrPollTask?.cancel()
            let cukList = (resp["cuktech"] as? [[String: Any]]) ?? []
            let allList = (resp["devices"] as? [[String: Any]]) ?? []
            let chosenRaw = cukList.isEmpty ? allList : cukList
            let devices: [XiaomiCloudDevice] = chosenRaw.compactMap { item in
                guard let did = item["did"] as? String, !did.isEmpty,
                      let mac = item["mac"] as? String, !mac.isEmpty else { return nil }
                let name = (item["name"] as? String) ?? ""
                let model = (item["model"] as? String) ?? ""
                return XiaomiCloudDevice(did: did, name: name.isEmpty ? (model.isEmpty ? mac : model) : name, mac: mac, model: model)
            }
            if devices.isEmpty {
                pairError = "当前小米账号下未找到可用的蓝牙充电器设备"
                return true
            }
            pairError = ""
            pairState = .selectingDevice(sessionID: sessionID, devices: devices)
            return true
        }

        let status = (resp["status"] as? String) ?? ""
        if status == "waiting" || status == "pending" {
            if manualTrigger {
                pairError = "尚未检测到手机确认，请在米家 App 扫码并点确认登录"
            }
            return false
        }

        if let err = resp["error"] as? String, !err.isEmpty {
            if err.contains("等待") || err.lowercased().contains("wait") || err.lowercased().contains("timeout") {
                if manualTrigger {
                    pairError = "尚未完成扫码确认，请用米家 App 扫码后点确认"
                }
                return false
            }
            pairError = err
        }
        return false
    }

    func importAndSaveXiaomiDevice(sessionID: String, device: XiaomiCloudDevice) {
        pairError = ""
        pairState = .importing(deviceName: device.name)

        Task {
            let impResp = await postRawJSON(
                path: "api/xiaomi/import",
                body: ["session_id": sessionID, "dids": [device.did]],
                timeout: 32.0
            )
            guard let impResp, Self.asBool(impResp["ok"]) == true,
                  let devList = impResp["devices"] as? [[String: Any]],
                  let first = devList.first else {
                pairState = .selectingDevice(sessionID: sessionID, devices: [device])
                pairError = (impResp?["error"] as? String) ?? "拉取设备密钥失败，请重试"
                return
            }

            if let itemErr = first["error"] as? String, !itemErr.isEmpty {
                pairState = .selectingDevice(sessionID: sessionID, devices: [device])
                pairError = "导入失败：\(itemErr)"
                return
            }

            let mac = (first["mac"] as? String) ?? device.mac
            let token = (first["token"] as? String) ?? ""
            let bleKey = (first["ble_key"] as? String) ?? ""
            let name = (first["name"] as? String) ?? device.name

            var bleDict: [String: Any] = [
                "mac": mac,
                "token": token,
                "ble_key": bleKey,
            ]
            if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                bleDict["name"] = name
            }

            let saveRes = await postJSON(path: "api/config", body: ["config": ["ble": bleDict]])
            if !saveRes.ok {
                pairState = .selectingDevice(sessionID: sessionID, devices: [device])
                pairError = "保存配置失败：\(saveRes.error ?? "未知错误")"
                return
            }

            pairState = .hidden
            showFeedback("已绑定「\(name)」，正在重启后端连接蓝牙…", isError: false)

            // Studio 后端收到 /api/config 后约 1 秒热重启，等待恢复后刷新
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for _ in 0..<16 {
                if await supervisor.checkBackendHealth() { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await refreshConfigAndStatus()
        }
    }

    func openLogFile() {
        let logURL = supervisor.logFileURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: supervisor.studioDataDir.path)
        }
    }

    // MARK: - 多设备切换

    func selectDevice(_ deviceID: String) {
        guard snapshot.currentDeviceID != deviceID else { return }
        snapshot.currentDeviceID = deviceID
        if let dev = snapshot.availableDevices.first(where: { $0.id == deviceID }) {
            snapshot.deviceName = dev.displayName
        }
        Task {
            await refreshStatus()
        }
    }

    // MARK: - 控制操作（单口通断 / 充电模式 / 重连）

    func setPortEnabled(_ port: PortReading, enabled: Bool) {
        guard snapshot.isBleReady, !isBusy else { return }
        isBusy = true
        showFeedback("正在\(enabled ? "开启" : "断开") \(port.label)…", isError: false, autoClear: false)

        Task {
            defer { isBusy = false }
            let body: [String: Any] = [
                "port": port.key,
                "action": enabled ? "on" : "off",
            ]
            let result = await postJSON(path: deviceScopedPath("api/port"), body: body)
            await refreshStatus()

            if result.ok {
                let actual = snapshot.ports.first(where: { $0.id == port.id })?.enabled ?? enabled
                if actual == enabled {
                    showFeedback("\(port.label) 已\(enabled ? "恢复供电" : "断电")", isError: false)
                } else {
                    showFeedback("已发送指令，设备回读仍为\(actual ? "开启" : "关闭")", isError: true)
                }
            } else {
                showFeedback("控制失败：\(result.error ?? "设备无响应")", isError: true)
            }
        }
    }

    func setAllPortsEnabled(_ enabled: Bool) {
        guard snapshot.isBleReady, !isBusy else { return }
        isBusy = true
        showFeedback("正在\(enabled ? "开启全部端口" : "断开全部端口")…", isError: false, autoClear: false)

        Task {
            defer { isBusy = false }
            let body: [String: Any] = [
                "port": "all",
                "action": enabled ? "on" : "off",
            ]
            let result = await postJSON(path: deviceScopedPath("api/port"), body: body)
            await refreshStatus()

            if result.ok {
                showFeedback(enabled ? "四口已全部恢复供电" : "四口已全部断电", isError: false)
            } else {
                showFeedback("操作失败：\(result.error ?? "设备无响应")", isError: true)
            }
        }
    }

    func setSceneMode(_ mode: Int) {
        guard snapshot.isBleReady, !isBusy else { return }
        let modeName = SceneModeOption.name(for: mode)
        isBusy = true
        showFeedback("正在切换到「\(modeName)」…", isError: false, autoClear: false)

        Task {
            defer { isBusy = false }
            let body: [String: Any] = [
                "piid": 5,
                "value": mode,
            ]
            let result = await postJSON(path: deviceScopedPath("api/set"), body: body)
            await refreshStatus()

            if result.ok {
                let readback = snapshot.sceneMode
                if readback == mode || readback == -1 {
                    snapshot.sceneMode = mode
                    notifySnapshotUpdated()
                    showFeedback("已切到「\(modeName)」（设备回读确认）", isError: false)
                } else {
                    showFeedback("已写入，但设备回读为「\(SceneModeOption.name(for: readback))」", isError: true)
                }
            } else {
                showFeedback("切换失败：\(result.error ?? "设备无响应")", isError: true)
            }
        }
    }

    func reconnectBLE() {
        guard snapshot.backendReady, !isBusy else { return }
        if snapshot.isHandshaking {
            showFeedback("正在连接握手中，请勿中断（约需 20~30 秒）", isError: false)
            return
        }
        isBusy = true
        snapshot.phase = "scanning"
        snapshot.phaseDetail = "正在重新搜索充电器广播…"
        notifySnapshotUpdated()
        showFeedback("正在重连蓝牙设备…", isError: false, autoClear: false)

        Task {
            defer { isBusy = false }
            _ = await postJSON(path: deviceScopedPath("api/enable"), body: ["enabled": false])
            try? await Task.sleep(nanoseconds: 600_000_000)
            let res = await postJSON(path: deviceScopedPath("api/enable"), body: ["enabled": true])
            await refreshStatus()
            if res.ok {
                showFeedback("已重新发起蓝牙扫描连接", isError: false)
            } else {
                showFeedback("重连指令失败：\(res.error ?? "未知错误")", isError: true)
            }
        }
    }

    func restartStudioService() {
        guard !isBusy else { return }
        isBusy = true
        snapshot.backendReady = false
        snapshot.sseConnected = false
        snapshot.connected = false
        snapshot.authenticated = false
        notifySnapshotUpdated()
        showFeedback("正在重启内置服务…", isError: false, autoClear: false)

        Task {
            defer { isBusy = false }
            await supervisor.restartServices()
            for _ in 0..<20 {
                if await supervisor.checkBackendHealth() { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await refreshConfigAndStatus()
            showFeedback("内置服务已就绪", isError: false)
        }
    }

    // MARK: - SSE 实时流与状态拉取

    private func runSSELoop() async {
        var retryDelayNs: UInt64 = 800_000_000

        while !Task.isCancelled {
            let backend = await supervisor.resolveActiveBackendURL()
            await refreshDevicesAndConfig()
            let eventsURL = backend.appendingPathComponent("api/events")
            var req = URLRequest(url: eventsURL)
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            do {
                let (bytes, response) = try await sseSession.bytes(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }

                snapshot.backendReady = true
                snapshot.sseConnected = true
                retryDelayNs = 800_000_000
                notifySnapshotUpdated()

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    if line.hasPrefix(":") || line.isEmpty { continue }
                    if line.hasPrefix("data:") {
                        let jsonPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        handleSSEPayload(String(jsonPart))
                    }
                }
            } catch {
                if Task.isCancelled { break }
                snapshot.sseConnected = false
                let healthy = await supervisor.checkBackendHealth()
                snapshot.backendReady = healthy
                snapshot.studioInstalled = supervisor.hasEmbeddedRuntime || healthy
                if !healthy {
                    snapshot.connected = false
                    snapshot.authenticated = false
                }
                notifySnapshotUpdated()
            }

            try? await Task.sleep(nanoseconds: retryDelayNs)
            retryDelayNs = min(retryDelayNs * 2, 4_000_000_000)
        }
    }

    func refreshConfigAndStatus() async {
        await refreshDevicesAndConfig()
        await refreshStatus()
    }

    func refreshDevicesAndConfig() async {
        if let devResp = await getJSON(path: "api/devices"),
           let rawList = devResp["devices"] as? [[String: Any]] {
            snapshot.backendReady = true
            applyDevicesList(rawList)
        } else if let cfgResp = await getJSON(path: "api/config"),
                  let cfg = cfgResp["config"] as? [String: Any],
                  let ble = cfg["ble"] as? [String: Any] {
            snapshot.backendReady = true
            let mac = (ble["mac"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.configured = Self.isValidConfiguredMac(mac)
            snapshot.configuredMac = mac
            if let name = ble["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                snapshot.deviceName = name
            }
        }
        notifySnapshotUpdated()
    }

    func refreshStatus() async {
        guard let dict = await getJSON(path: deviceScopedPath("api/status")) else {
            let healthy = await supervisor.checkBackendHealth()
            snapshot.backendReady = healthy
            notifySnapshotUpdated()
            return
        }
        snapshot.backendReady = true
        applyFullStatusDict(dict)
        notifySnapshotUpdated()
    }

    // MARK: - SSE 与状态字典解析

    func handleSSEPayload(_ rawJSON: String) {
        guard let data = rawJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        let type = dict["type"] as? String ?? ""
        if type == "init", let rawDevices = dict["devices"] as? [[String: Any]] {
            applyDevicesList(rawDevices)
        }

        // 多设备分流：非当前选中设备的增量事件仅更新其在线标记，不覆盖当前面板数据
        if let eventDev = dict["device"] as? String, !eventDev.isEmpty, eventDev != snapshot.currentDeviceID {
            if let conn = Self.asBool(dict["connected"]),
               let idx = snapshot.availableDevices.firstIndex(where: { $0.id == eventDev }) {
                snapshot.availableDevices[idx].connected = conn
            }
            return
        }

        switch type {
        case "init":
            if snapshot.currentDeviceID == "default" {
                applyFullStatusDict(dict)
            } else {
                Task { await refreshStatus() }
            }
        case "port_update":
            let portID = Self.asInt(dict["port_id"]) ?? Self.portIDFromKey(dict["port"] as? String)
            if let portID, let portData = dict["data"] as? [String: Any] {
                applySinglePortUpdate(id: portID, dict: portData)
            }
        case "phase":
            if let phase = dict["phase"] as? String {
                snapshot.phase = phase
            }
        case "status":
            if dict["connected"] == nil {
                if let phase = dict["phase"] as? String {
                    snapshot.phase = phase
                }
            } else {
                applyFullStatusDict(dict)
            }
        case "settings":
            if let settings = dict["settings"] as? [String: Any] {
                applySettingsDict(settings)
            }
        default:
            break
        }
        notifySnapshotUpdated()
    }

    private func applyDevicesList(_ rawList: [[String: Any]]) {
        var parsed: [StudioDeviceSummary] = []
        for (i, item) in rawList.enumerated() {
            let id = (item["id"] as? String) ?? (i == 0 ? "default" : "dev-\(i)")
            let name = (item["name"] as? String) ?? ""
            let mac = (item["mac"] as? String) ?? ""
            let isPrimary = Self.asBool(item["is_primary"]) ?? (i == 0)
            let connected = Self.asBool(item["connected"]) ?? false
            if Self.isValidConfiguredMac(mac) {
                parsed.append(StudioDeviceSummary(
                    id: id,
                    name: name,
                    mac: mac,
                    isPrimary: isPrimary,
                    connected: connected
                ))
            }
        }
        snapshot.availableDevices = parsed
        snapshot.configured = !parsed.isEmpty

        if let current = parsed.first(where: { $0.id == snapshot.currentDeviceID }) {
            snapshot.configuredMac = current.mac
            if current.name != current.id && !current.name.isEmpty {
                snapshot.deviceName = current.name
            }
        } else if let first = parsed.first {
            snapshot.currentDeviceID = first.id
            snapshot.configuredMac = first.mac
            snapshot.deviceName = first.displayName
        } else {
            snapshot.currentDeviceID = "default"
            snapshot.configuredMac = ""
            snapshot.deviceName = "酷态科 10 号 Ultra"
        }
    }

    private func applyFullStatusDict(_ dict: [String: Any]) {
        if let conn = Self.asBool(dict["connected"]) {
            snapshot.connected = conn
        }
        if let auth = Self.asBool(dict["authenticated"]) {
            snapshot.authenticated = auth
        }
        if snapshot.isBleReady {
            snapshot.phase = "ready"
            snapshot.phaseDetail = ""
        } else if let phase = dict["phase"] as? String, !phase.isEmpty {
            snapshot.phase = phase
        }
        if let model = dict["device_model"] as? String, !model.isEmpty {
            snapshot.deviceModel = model
        }
        if let fw = dict["firmware_version"] as? String, !fw.isEmpty {
            snapshot.firmwareVersion = fw
        }
        if let settings = dict["settings"] as? [String: Any] {
            applySettingsDict(settings)
        }

        if !snapshot.isBleReady {
            for idx in snapshot.ports.indices {
                snapshot.ports[idx].voltage = 0
                snapshot.ports[idx].current = 0
                snapshot.ports[idx].power = 0
                snapshot.ports[idx].active = false
                snapshot.ports[idx].protocolName = "idle"
            }
        } else if let portsDict = dict["ports"] as? [String: Any] {
            for id in 1...4 {
                if let pDict = (portsDict["\(id)"] as? [String: Any]) {
                    applySinglePortUpdate(id: id, dict: pDict)
                }
            }
        }
    }

    private func applySettingsDict(_ settings: [String: Any]) {
        if let mode = Self.asInt(settings["5"]) {
            snapshot.sceneMode = mode
        }
        if let mask = Self.asInt(settings["16"]) {
            snapshot.portSwitchMask = mask
            for idx in snapshot.ports.indices {
                let bit = 1 << (snapshot.ports[idx].id - 1)
                snapshot.ports[idx].enabled = (mask & bit) != 0
            }
        }
    }

    private func applySinglePortUpdate(id: Int, dict: [String: Any]) {
        guard let idx = snapshot.ports.firstIndex(where: { $0.id == id }) else { return }
        if let v = Self.asDouble(dict["voltage"]) { snapshot.ports[idx].voltage = v }
        if let c = Self.asDouble(dict["current"]) { snapshot.ports[idx].current = c }
        if let w = Self.asDouble(dict["power"])   { snapshot.ports[idx].power = w }
        if let a = Self.asBool(dict["active"])    { snapshot.ports[idx].active = a }
        if let e = Self.asBool(dict["enabled"])   { snapshot.ports[idx].enabled = e }
        if let proto = dict["protocol"] as? String { snapshot.ports[idx].protocolName = proto }
        snapshot.ports[idx].capPowerW = Self.asInt(dict["cap_power_w"])
    }

    private func notifySnapshotUpdated() {
        onSnapshotChanged?(snapshot)
    }

    private func showFeedback(_ text: String, isError: Bool, autoClear: Bool = true) {
        clearFeedbackTask?.cancel()
        feedbackMessage = text
        feedbackIsError = isError
        if autoClear {
            clearFeedbackTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                self?.feedbackMessage = ""
            }
        }
    }

    // MARK: - HTTP 辅助

    private func deviceScopedPath(_ basePath: String) -> String {
        guard snapshot.currentDeviceID != "default" else { return basePath }
        let encoded = snapshot.currentDeviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? snapshot.currentDeviceID
        if basePath.hasPrefix("api/") {
            let sub = basePath.dropFirst(4)
            return "api/device/\(encoded)/\(sub)"
        }
        return basePath
    }

    private func buildBackendURL(path: String) -> URL {
        supervisor.activeBackendURL.appendingPathComponent(path)
    }

    private func getJSON(path: String) async -> [String: Any]? {
        let url = buildBackendURL(path: path)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, resp) = try await apiSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func postRawJSON(path: String, body: [String: Any], timeout: TimeInterval = 15.0) async -> [String: Any]? {
        let url = buildBackendURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(supervisor.activeBackendURL.absoluteString, forHTTPHeaderField: "Origin")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await apiSession.data(for: req)
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func postJSON(path: String, body: [String: Any]) async -> (ok: Bool, error: String?) {
        let url = buildBackendURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(supervisor.activeBackendURL.absoluteString, forHTTPHeaderField: "Origin")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await apiSession.data(for: req)
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let ok = Self.asBool(dict?["ok"]) {
                return (ok, dict?["error"] as? String)
            }
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return (true, nil)
            }
            return (false, dict?["error"] as? String ?? "请求失败")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - 类型与格式校验工具

    private func syncHandshakePhaseFromLog() {
        // 仅当活跃后端指向本机时读取本机 backend.log 末尾 4 KB
        let host = supervisor.activeBackendURL.host ?? "127.0.0.1"
        guard host == "127.0.0.1" || host == "localhost" else { return }
        let logURL = supervisor.logFileURL
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? fh.close() }

        let endOffset = (try? fh.seekToEnd()) ?? 0
        let readLen: UInt64 = min(endOffset, 4096)
        try? fh.seek(toOffset: endOffset - readLen)
        guard let data = try? fh.readToEnd(),
              let tail = String(data: data, encoding: .utf8),
              let parsed = Self.parseHandshakePhase(fromLogTail: tail) else {
            return
        }

        if snapshot.phase != parsed.phase || snapshot.phaseDetail != parsed.detail {
            snapshot.phase = parsed.phase
            snapshot.phaseDetail = parsed.detail
            notifySnapshotUpdated()
        }
    }

    static func parseHandshakePhase(fromLogTail tail: String) -> (phase: String, detail: String)? {
        let lines = tail.components(separatedBy: .newlines).reversed()
        for line in lines {
            guard line.contains("cuktech_ble") else { continue }
            if line.contains("Authenticated!") || line.contains("认证成功") {
                return ("ready", "")
            }
            for step in (1...5).reversed() {
                if line.contains("[\(step)/5]") {
                    return ("authenticating", "正在加密认证 [\(step)/5]…")
                }
            }
            if line.contains("开始 MiOT BLE 认证") || line.contains("authenticating...") {
                return ("authenticating", "正在加密认证 [1/5]…")
            }
            if line.contains("Negotiated MTU")
                || line.contains("waiting for device to settle")
                || line.contains("Reading device info") {
                return ("connecting", "蓝牙已连上，同步设备信息…")
            }
            if line.contains("Connecting to ") {
                return ("connecting", "正在建立蓝牙连接…")
            }
            if line.contains("Scanning for charger") {
                return ("scanning", "正在搜索充电器广播…")
            }
            if (line.contains("Waiting ") && line.contains("before retry"))
                || line.contains("Charger not found")
                || line.contains("BLE loop error") {
                return ("retrying", "未扫到设备（等待自动重试）")
            }
        }
        return nil
    }

    static func isValidConfiguredMac(_ raw: String) -> Bool {
        let hexScalars = raw.unicodeScalars.filter {
            ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
        }
        let hex = String(String.UnicodeScalarView(hexScalars)).lowercased()
        return hex.count == 12 && hex != "000000000000" && hex != "aabbccddeeff"
    }

    private static func portIDFromKey(_ key: String?) -> Int? {
        switch key?.lowercased() {
        case "c1": return 1
        case "c2": return 2
        case "c3": return 3
        case "a":  return 4
        default:   return nil
        }
    }

    private static func asDouble(_ val: Any?) -> Double? {
        if let d = val as? Double { return d }
        if let i = val as? Int { return Double(i) }
        if let n = val as? NSNumber { return n.doubleValue }
        if let s = val as? String { return Double(s) }
        return nil
    }

    private static func asInt(_ val: Any?) -> Int? {
        if let i = val as? Int { return i }
        if let n = val as? NSNumber { return n.intValue }
        if let s = val as? String { return Int(s) }
        return nil
    }

    private static func asBool(_ val: Any?) -> Bool? {
        if let b = val as? Bool { return b }
        if let n = val as? NSNumber { return n.boolValue }
        return nil
    }
}
