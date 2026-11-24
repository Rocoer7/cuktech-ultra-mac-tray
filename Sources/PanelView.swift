import SwiftUI

/// 三页签迷你面板视图（读数 / 控制 / 模式 + 一键打开 CUKTECH Studio 工作台）
struct PanelView: View {
    @ObservedObject var store: Smart10uStore
    var onRequestQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            if store.pairState != .hidden {
                xiaomiPairingCard
            } else {
                if store.snapshot.availableDevices.count > 1 {
                    deviceSwitcherBar
                }

                if store.snapshot.backendReady && !store.snapshot.configured {
                    unconfiguredBanner
                }

                tabBar

                Group {
                    switch store.selectedTab {
                    case .read:
                        readTab
                    case .control:
                        controlTab
                    case .mode:
                        modeTab
                    }
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.10))

            footerBar
        }
        .padding(14)
        .frame(width: 344)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                Color(red: 20 / 255, green: 23 / 255, blue: 28 / 255).opacity(0.82)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 顶栏：设备状态 + Studio 工作台 + 图钉

    private var headerBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.6), radius: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.snapshot.deviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(store.snapshot.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                store.openDashboard()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 11, weight: .semibold))
                    Text("工作台")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color(red: 125 / 255, green: 211 / 255, blue: 252 / 255))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("在浏览器打开 CUKTECH Studio 工作台（http://127.0.0.1:18383）")

            Button {
                store.isPinned.toggle()
            } label: {
                Image(systemName: store.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(
                        store.isPinned
                            ? Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
                            : .white.opacity(0.65)
                    )
                    .frame(width: 26, height: 26)
                    .background(
                        store.isPinned
                            ? Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255).opacity(0.16)
                            : Color.white.opacity(0.07)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(store.isPinned ? "解除桌面固定（点击外部自动收起）" : "固定面板到桌面（记住位置）")
        }
    }

    private var deviceSwitcherBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.snapshot.availableDevices) { dev in
                    let active = store.snapshot.currentDeviceID == dev.id
                    Button {
                        store.selectDevice(dev.id)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(dev.connected
                                      ? Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
                                      : Color.white.opacity(0.3))
                                .frame(width: 5, height: 5)
                            Text(dev.displayName)
                                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                                .foregroundColor(active ? .white : .white.opacity(0.65))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(active ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var statusDotColor: Color {
        if !store.snapshot.studioInstalled || !store.snapshot.backendReady {
            return .orange
        }
        if !store.snapshot.configured {
            return Color(red: 125 / 255, green: 211 / 255, blue: 252 / 255)
        }
        if store.snapshot.isBleReady {
            return Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
        }
        if ["scanning", "connecting", "authenticating"].contains(store.snapshot.phase) {
            return Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
        }
        return Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
    }

    // MARK: - 未添加充电器引导横幅

    private var unconfiguredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 18))
                .foregroundColor(Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255))

            VStack(alignment: .leading, spacing: 2) {
                Text("尚未绑定充电器")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text("直接在此面板用米家 App 扫码导入到 Studio")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.68))
            }

            Spacer()

            Button {
                store.startXiaomiPairing()
            } label: {
                Text("扫码绑定")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255).opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255).opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - 页签栏

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { tab in
                let selected = store.selectedTab == tab
                Button {
                    store.selectedTab = tab
                    if tab != .read {
                        Task { await store.refreshStatus() }
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundColor(selected ? .white : .white.opacity(0.60))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            selected
                                ? Color.white.opacity(0.14)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - 页签 1：读数

    private var readTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            let total = store.snapshot.totalWatts
            let totalColor = WattStyle.panelColor(
                for: WattStyle.totalTier(total, connected: store.snapshot.isBleReady)
            )

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("四口总输出")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))

                    HStack(spacing: 6) {
                        if store.snapshot.isBleReady {
                            Text("\(store.snapshot.activePortCount) 口供电中")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.50))
                        } else {
                            Text("等待设备数据")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.42))
                        }

                        if store.snapshot.sceneMode > 0 {
                            Text("· \(SceneModeOption.name(for: store.snapshot.sceneMode))")
                                .font(.system(size: 11))
                                .foregroundColor(Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255).opacity(0.85))
                        }
                    }
                }

                Spacer()

                if store.snapshot.isBleReady {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(WattStyle.formatWatts(total))
                            .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(totalColor)
                        Text("W")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(totalColor.opacity(0.85))
                    }
                } else {
                    Text("— W")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(WattStyle.panelColor(for: .dim))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text("端口")
                    .frame(width: 98, alignment: .leading)
                Spacer()
                Text("电压")
                    .frame(width: 58, alignment: .trailing)
                Text("电流")
                    .frame(width: 54, alignment: .trailing)
                Text("功率")
                    .frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.white.opacity(0.42))
            .padding(.horizontal, 8)

            VStack(spacing: 6) {
                ForEach(store.snapshot.ports) { port in
                    portReadRow(port)
                }
            }
        }
    }

    private func portReadRow(_ port: PortReading) -> some View {
        let active = store.snapshot.isBleReady && port.isWorking && port.enabled
        let pColor = WattStyle.panelColor(for: WattStyle.portTier(port.power, active: active))

        return HStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(port.label)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(port.enabled ? .white : .white.opacity(0.40))

                if let badge = port.displayProtocol {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(
                            port.enabled
                                ? Color(red: 125 / 255, green: 211 / 255, blue: 252 / 255)
                                : Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
                        )
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            (port.enabled
                                ? Color(red: 125 / 255, green: 211 / 255, blue: 252 / 255)
                                : Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
                            ).opacity(0.15)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .lineLimit(1)
                }
            }
            .frame(width: 106, alignment: .leading)

            Spacer(minLength: 0)

            Text(active ? String(format: "%.1fV", port.voltage) : "—")
                .font(.system(size: 12, weight: .regular).monospacedDigit())
                .foregroundColor(active ? .white.opacity(0.85) : .white.opacity(0.30))
                .frame(width: 56, alignment: .trailing)

            Text(active ? String(format: "%.1fA", port.current) : "—")
                .font(.system(size: 12, weight: .regular).monospacedDigit())
                .foregroundColor(active ? .white.opacity(0.85) : .white.opacity(0.30))
                .frame(width: 52, alignment: .trailing)

            Text(active ? "\(WattStyle.formatWatts(port.power))W" : "—")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundColor(active ? pColor : .white.opacity(0.30))
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(active ? 0.065 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 页签 2：控制（单口通断）

    private var controlTab: some View {
        let ready = store.snapshot.isBleReady && !store.isBusy

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(store.snapshot.ports) { port in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(port.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            if !port.enabled {
                                Text("已断电")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255))
                            }
                        }

                        Text(controlSubtitle(for: port))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.white.opacity(0.55))
                    }

                    Spacer()

                    PortSwitchPill(isOn: port.enabled, isEnabled: ready) {
                        store.setPortEnabled(port, enabled: !port.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack(spacing: 8) {
                Button {
                    store.setAllPortsEnabled(true)
                } label: {
                    Text("全部恢复供电")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ready ? .white.opacity(0.88) : .white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!ready)

                Button {
                    store.openDashboard()
                } label: {
                    Text("Studio 更多控制…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 125 / 255, green: 211 / 255, blue: 252 / 255))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .opacity(store.snapshot.isBleReady ? 1.0 : 0.62)
    }

    private func controlSubtitle(for port: PortReading) -> String {
        guard store.snapshot.isBleReady else {
            return "未连接充电器（禁止盲写）"
        }
        if !port.enabled {
            return "端口输出已关闭"
        }
        if port.isWorking {
            return String(format: "%.1fV · %.1fA · %@W", port.voltage, port.current, WattStyle.formatWatts(port.power))
        }
        return "供电开启 · 空闲"
    }

    // MARK: - 页签 3：充电模式（四档场景）

    private var modeTab: some View {
        let ready = store.snapshot.isBleReady && !store.isBusy
        let green = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)

        return VStack(alignment: .leading, spacing: 7) {
            ForEach(SceneModeOption.all) { item in
                let isCurrent = store.snapshot.isBleReady && store.snapshot.sceneMode == item.id

                Button {
                    guard ready else { return }
                    store.setSceneMode(item.id)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isCurrent ? green : Color.white.opacity(0.14))
                            .frame(width: 3.5, height: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(.white)

                                if isCurrent {
                                    Text("当前")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(green)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }
                            }

                            Text(item.hint)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.58))
                                .lineLimit(1)
                        }

                        Spacer()

                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(green)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isCurrent ? green.opacity(0.12) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isCurrent ? green.opacity(0.65) : Color.white.opacity(0.06), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!ready)
            }
        }
        .opacity(store.snapshot.isBleReady ? 1.0 : 0.60)
    }

    // MARK: - 内置小米云扫码绑定卡片

    private var xiaomiPairingCard: some View {
        let green = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
        let amber = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)

        return VStack(alignment: .center, spacing: 10) {
            HStack {
                Text("米家 App 扫码导入")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    store.cancelXiaomiPairing()
                } label: {
                    Text("返回面板")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            switch store.pairState {
            case .hidden:
                EmptyView()

            case .loadingQR:
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在从小米云获取登录二维码…")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.70))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)

            case let .showingQR(_, qrBase64, loginURL):
                VStack(spacing: 10) {
                    if let nsImg = decodeBase64Image(qrBase64) {
                        Image(nsImage: nsImg)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 168, height: 168)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Text("二维码图像解析失败")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }

                    Text("打开手机米家 App → 右上角「+」→「扫一扫」确认登录")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Button {
                            store.checkXiaomiQRNow()
                        } label: {
                            Text("我已扫码")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(green)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.startXiaomiPairing()
                        } label: {
                            Text("刷新二维码")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        if let url = URL(string: loginURL), loginURL.hasPrefix("https://") {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Text("网页登录")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(Color(red: 125 / 255, green: 211 / 255, blue: 252 / 255))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)

            case let .selectingDevice(sessionID, devices):
                VStack(alignment: .leading, spacing: 7) {
                    Text("点击要绑定的充电器（自动写入 Studio 并生效）：")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.68))

                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(devices) { dev in
                                Button {
                                    store.importAndSaveXiaomiDevice(sessionID: sessionID, device: dev)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(dev.name)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundColor(.white)
                                            Text("\(dev.mac)\(dev.model.isEmpty ? "" : " · \(dev.model)")")
                                                .font(.system(size: 10.5).monospacedDigit())
                                                .foregroundColor(.white.opacity(0.55))
                                        }
                                        Spacer()
                                        Text("绑定此台")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.black)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(amber)
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }

            case let .importing(deviceName):
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在拉取「\(deviceName)」密钥并写入 Studio…")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            }

            if !store.pairError.isEmpty {
                Text(store.pairError)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func decodeBase64Image(_ raw: String) -> NSImage? {
        let cleaned = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return NSImage(data: data)
    }

    // MARK: - 底栏：反馈与快捷动作

    private var footerBar: some View {
        HStack(spacing: 10) {
            if !store.feedbackMessage.isEmpty {
                Text(store.feedbackMessage)
                    .font(.system(size: 11))
                    .foregroundColor(
                        store.feedbackIsError
                            ? Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
                            : Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Button {
                    store.startXiaomiPairing()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 10.5))
                        Text("扫码绑定")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white.opacity(0.62))
                }
                .buttonStyle(.plain)

                Text("·")
                    .foregroundColor(.white.opacity(0.28))

                if store.snapshot.isHandshaking {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在握手，请稍候…")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255))
                    }
                } else {
                    Button {
                        store.reconnectBLE()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10.5))
                            Text("重连蓝牙")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.white.opacity(0.62))
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.snapshot.backendReady || store.isBusy)
                }
            }

            Spacer(minLength: 4)

            if !store.snapshot.firmwareVersion.isEmpty && store.feedbackMessage.isEmpty {
                Text("FW \(store.snapshot.firmwareVersion)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.white.opacity(0.35))
            }

            Button {
                onRequestQuit()
            } label: {
                Text("退出")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("退出状态栏应用并同步停止 CUKTECH Studio")
        }
    }
}

private struct PortSwitchPill: View {
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        let activeColor = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? activeColor : Color.white.opacity(0.18))
                    .frame(width: 40, height: 22)

                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .padding(.horizontal, 2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
