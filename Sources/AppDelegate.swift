import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated static let showPanelNotification = Notification.Name("com.morty626.cuktechstudio.showPanel")

    private let supervisor = BackendSupervisor()
    private lazy var store = Smart10uStore(supervisor: supervisor)
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    private let trayOnlyOnLaunch: Bool
    private let forceOpenPanelOnLaunch: Bool
    private let initialTab: PanelTab?

    init(trayOnly: Bool, forcePanel: Bool, initialTab: PanelTab?) {
        self.trayOnlyOnLaunch = trayOnly
        self.forceOpenPanelOnLaunch = forcePanel
        self.initialTab = initialTab
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()

        panelController = PanelController(store: store) { [weak self] in
            self?.quitApp()
        }

        setupStatusItem()

        store.onSnapshotChanged = { [weak self] snap in
            self?.updateStatusItemAppearance(with: snap)
        }
        store.onPinChanged = { [weak self] pinned in
            self?.panelController.applyPinBehavior(isPinned: pinned)
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalShowPanel(_:)),
            name: Self.showPanelNotification,
            object: nil
        )

        updateStatusItemAppearance(with: store.snapshot)
        store.start()

        if store.isPinned || forceOpenPanelOnLaunch || !trayOnlyOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.panelController.show(
                    relativeTo: self.statusItem.button,
                    selectTab: self.initialTab
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        store.shutdown()
    }

    // MARK: - 单一状态栏图标（原生单色模板闪电 + 五档彩色功率文字）

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let boltURL = supervisor.contentsDir.appendingPathComponent("Resources/desktop/menu-b-bolt.png")
        if let boltImg = NSImage(contentsOf: boltURL) {
            boltImg.size = NSSize(width: 15, height: 15)
            boltImg.isTemplate = true
            button.image = boltImg
            button.imagePosition = .imageLeft
        } else if let sfBolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "CUKTECH") {
            sfBolt.isTemplate = true
            button.image = sfBolt
            button.imagePosition = .imageLeft
        }
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            panelController.toggle(relativeTo: sender)
            return
        }

        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isRightClick {
            panelController.hide()
            let menu = buildContextMenu()
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            panelController.toggle(relativeTo: sender)
        }
    }

    @objc private func handleExternalShowPanel(_ notification: Notification) {
        panelController.show(relativeTo: statusItem.button)
    }

    private func updateStatusItemAppearance(with snap: ChargerSnapshot) {
        guard let button = statusItem.button else { return }

        let text: String
        let color: NSColor

        if !snap.studioInstalled {
            text = " 缺运行库"
            color = WattStyle.statusBarNSColor(for: .bad)
        } else if !snap.backendReady {
            text = " 启动中"
            color = WattStyle.statusBarNSColor(for: .dim)
        } else if !snap.configured {
            text = " 待绑定"
            color = WattStyle.statusBarNSColor(for: .warn)
        } else if snap.isBleReady {
            let total = snap.totalWatts
            text = " \(WattStyle.formatWatts(total))W"
            color = WattStyle.statusBarNSColor(for: WattStyle.totalTier(total, connected: true))
        } else if snap.isHandshaking {
            text = " 连接中"
            color = WattStyle.statusBarNSColor(for: .warn)
        } else {
            text = " --W"
            color = WattStyle.statusBarNSColor(for: .dim)
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let attr = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .baselineOffset: -0.5,
            ]
        )
        button.attributedTitle = attr
        button.toolTip = buildTooltip(for: snap)
    }

    private func buildTooltip(for snap: ChargerSnapshot) -> String {
        var lines: [String] = []
        if snap.isBleReady {
            lines.append("\(snap.deviceName) · 总 \(WattStyle.formatWatts(snap.totalWatts)) W")
            for p in snap.ports {
                if !p.enabled {
                    lines.append("\(p.label): 已断电")
                } else if p.isWorking {
                    lines.append(
                        String(
                            format: "%@: %.1fV / %.1fA / %@W",
                            p.label, p.voltage, p.current, WattStyle.formatWatts(p.power)
                        )
                    )
                } else {
                    lines.append("\(p.label): 空闲")
                }
            }
        } else {
            lines.append("\(snap.deviceName) · \(snap.statusText)")
        }
        lines.append("左键：打开面板 ｜ 右键：快捷菜单")
        return lines.joined(separator: "\n")
    }

    // MARK: - 右键快捷菜单

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let snap = store.snapshot

        let headerTitle = snap.isBleReady
            ? "已连接 · 总 \(WattStyle.formatWatts(snap.totalWatts)) W"
            : snap.statusText
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(.separator())

        let readItem = NSMenuItem(title: "显示功率面板", action: #selector(menuShowReadTab), keyEquivalent: "")
        readItem.target = self
        menu.addItem(readItem)

        let ctrlItem = NSMenuItem(title: "显示单口控制页", action: #selector(menuShowControlTab), keyEquivalent: "")
        ctrlItem.target = self
        menu.addItem(ctrlItem)

        let modeMenu = NSMenu()
        for opt in SceneModeOption.all {
            let item = NSMenuItem(title: opt.name, action: #selector(menuSelectSceneMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = opt.id
            item.state = (snap.isBleReady && snap.sceneMode == opt.id) ? .on : .off
            item.isEnabled = snap.isBleReady && !store.isBusy
            modeMenu.addItem(item)
        }
        let modeParent = NSMenuItem(title: "充电模式", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        menu.addItem(.separator())

        let webDashItem = NSMenuItem(
            title: "打开网页工作台 (曲线/历史/详情)…",
            action: #selector(menuOpenDashboard),
            keyEquivalent: ""
        )
        webDashItem.target = self
        menu.addItem(webDashItem)

        let pairItem = NSMenuItem(
            title: "米家扫码绑定充电器…",
            action: #selector(menuStartXiaomiPair),
            keyEquivalent: ""
        )
        pairItem.target = self
        menu.addItem(pairItem)

        menu.addItem(.separator())

        let pinItem = NSMenuItem(title: "固定面板到桌面", action: #selector(menuTogglePin), keyEquivalent: "")
        pinItem.target = self
        pinItem.state = store.isPinned ? .on : .off
        menu.addItem(pinItem)

        let autoStartItem = NSMenuItem(title: "随 macOS 登录启动", action: #selector(menuToggleAutoStart), keyEquivalent: "")
        autoStartItem.target = self
        autoStartItem.state = LaunchAgentHelper.isEnabled ? .on : .off
        menu.addItem(autoStartItem)

        menu.addItem(.separator())

        let reconnectTitle = snap.isHandshaking ? "蓝牙连接握手中…" : "重新连接蓝牙"
        let reconnectItem = NSMenuItem(title: reconnectTitle, action: #selector(menuReconnectBLE), keyEquivalent: "")
        reconnectItem.target = self
        reconnectItem.isEnabled = snap.backendReady && !store.isBusy && !snap.isHandshaking
        menu.addItem(reconnectItem)

        let restartSvcItem = NSMenuItem(title: "重启内置后台服务", action: #selector(menuRestartStudio), keyEquivalent: "")
        restartSvcItem.target = self
        menu.addItem(restartSvcItem)

        let logItem = NSMenuItem(title: "查看运行日志", action: #selector(menuOpenLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quitAllItem = NSMenuItem(title: "退出", action: #selector(menuQuitAll), keyEquivalent: "q")
        quitAllItem.target = self
        menu.addItem(quitAllItem)

        return menu
    }

    // MARK: - 菜单动作

    @objc private func menuShowReadTab() {
        panelController.show(relativeTo: statusItem.button, selectTab: .read)
    }

    @objc private func menuShowControlTab() {
        panelController.show(relativeTo: statusItem.button, selectTab: .control)
    }

    @objc private func menuSelectSceneMode(_ sender: NSMenuItem) {
        store.setSceneMode(sender.tag)
    }

    @objc private func menuOpenDashboard() {
        store.openDashboard()
    }

    @objc private func menuStartXiaomiPair() {
        panelController.show(relativeTo: statusItem.button)
        store.startXiaomiPairing()
    }

    @objc private func menuTogglePin() {
        store.isPinned.toggle()
        if store.isPinned, !panelController.isVisible {
            panelController.show(relativeTo: statusItem.button)
        }
    }

    @objc private func menuToggleAutoStart() {
        let next = !LaunchAgentHelper.isEnabled
        _ = LaunchAgentHelper.setEnabled(next)
    }

    @objc private func menuReconnectBLE() {
        store.reconnectBLE()
    }

    @objc private func menuRestartStudio() {
        store.restartStudioService()
    }

    @objc private func menuOpenLog() {
        store.openLogFile()
    }

    @objc private func menuQuitAll() {
        quitApp()
    }

    private func quitApp() {
        panelController.hide()
        NSApp.terminate(nil)
    }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSrc.setEventHandler { [weak self] in
            self?.quitApp()
        }
        termSrc.resume()
        self.sigtermSource = termSrc

        let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSrc.setEventHandler { [weak self] in
            self?.quitApp()
        }
        intSrc.resume()
        self.sigintSource = intSrc
    }
}
