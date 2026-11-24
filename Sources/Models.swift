import Foundation

/// 单个充电口的实时读数与开关状态
struct PortReading: Identifiable, Equatable {
    let id: Int          // 1=C1, 2=C2, 3=C3, 4=USB-A
    let key: String      // "c1", "c2", "c3", "a"
    let label: String    // "C1", "C2", "C3", "USB-A"
    var voltage: Double = 0.0
    var current: Double = 0.0
    var power: Double = 0.0
    var active: Bool = false
    var enabled: Bool = true
    var protocolName: String = "idle"
    var capPowerW: Int? = nil

    var isWorking: Bool {
        active || power > 0.05 || (voltage > 0.5 && current > 0.05)
    }

    var displayProtocol: String? {
        guard enabled else { return "已断电" }
        let trimmed = protocolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "idle" || trimmed.lowercased() == "none" {
            return nil
        }
        return trimmed.uppercased()
    }

    static let defaults: [PortReading] = [
        PortReading(id: 1, key: "c1", label: "C1"),
        PortReading(id: 2, key: "c2", label: "C2"),
        PortReading(id: 3, key: "c3", label: "C3"),
        PortReading(id: 4, key: "a",  label: "USB-A"),
    ]
}

/// CUKTECH Studio 中的设备条目（支持多台充电器切换）
struct StudioDeviceSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let mac: String
    let isPrimary: Bool
    var connected: Bool

    var displayName: String {
        if !name.isEmpty && name != id && name != "default" {
            return name
        }
        return isPrimary ? "主充电器" : id
    }
}

/// 小米云扫码发现的待导入设备
struct XiaomiCloudDevice: Identifiable, Equatable {
    let did: String
    let name: String
    let mac: String
    let model: String

    var id: String { did }
}

/// 内置小米云扫码绑定状态机
enum XiaomiPairState: Equatable {
    case hidden
    case loadingQR
    case showingQR(sessionID: String, qrBase64: String, loginURL: String)
    case selectingDevice(sessionID: String, devices: [XiaomiCloudDevice])
    case importing(deviceName: String)
}

/// 四档充电模式（SIID=2, PIID=5，对齐 cuktech-ultra-tray 与米家场景模式）
struct SceneModeOption: Identifiable, Equatable {
    let id: Int
    let name: String
    let hint: String

    static let all: [SceneModeOption] = [
        SceneModeOption(id: 1, name: "AI 智能",  hint: "插上什么就按什么给，自动分配功率"),
        SceneModeOption(id: 2, name: "数码生态", hint: "优先照顾自家设备，出厂默认"),
        SceneModeOption(id: 3, name: "极速单口", hint: "只给一路快充，其余让路"),
        SceneModeOption(id: 4, name: "均衡输出", hint: "四路平分，谁都不落下"),
    ]

    static func name(for value: Int) -> String {
        all.first(where: { $0.id == value })?.name ?? "模式 \(value)"
    }
}

/// 面板三大页签
enum PanelTab: Int, CaseIterable, Identifiable {
    case read = 0
    case control = 1
    case mode = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .read:    return "读数"
        case .control: return "控制"
        case .mode:    return "模式"
        }
    }
}

/// 充电器与 CUKTECH Studio 后端服务的聚合快照
struct ChargerSnapshot: Equatable {
    var studioInstalled: Bool = true
    var backendReady: Bool = false
    var sseConnected: Bool = false
    var configured: Bool = true
    var configuredMac: String = ""
    var currentDeviceID: String = "default"
    var availableDevices: [StudioDeviceSummary] = []

    var deviceName: String = "酷态科 10 号 Ultra"
    var deviceModel: String = ""
    var firmwareVersion: String = ""

    var connected: Bool = false
    var authenticated: Bool = false
    var phase: String = "idle"
    var phaseDetail: String = ""

    var ports: [PortReading] = PortReading.defaults
    /// SIID=2 PIID=16 位掩码（bit0=C1..bit3=A）
    var portSwitchMask: Int = 0x0F
    /// SIID=2 PIID=5 充电模式（1..4，-1 表示暂未读取）
    var sceneMode: Int = -1

    var isBleReady: Bool {
        backendReady && connected && authenticated
    }

    /// 是否正处于扫描 / 物理建链 / 五步加密握手中（此期间禁止手动重连掐断）
    var isHandshaking: Bool {
        backendReady && configured && !isBleReady
            && ["scanning", "connecting", "authenticating"].contains(phase)
    }

    var totalWatts: Double {
        guard isBleReady else { return 0.0 }
        return ports.reduce(0.0) { acc, p in
            acc + (p.isWorking ? max(0.0, p.power) : 0.0)
        }
    }

    var activePortCount: Int {
        guard isBleReady else { return 0 }
        return ports.filter(\.isWorking).count
    }

    var statusText: String {
        if !studioInstalled {
            return "未检测到 CUKTECH Studio.app"
        }
        if !backendReady {
            return "正在启动 CUKTECH Studio…"
        }
        if !configured {
            return "待在 Studio 工作台添加设备"
        }
        if isBleReady {
            return "已连接"
        }
        if !phaseDetail.isEmpty {
            return phaseDetail
        }
        switch phase {
        case "scanning":       return "搜索充电器…"
        case "connecting":     return "正在建立蓝牙连接…"
        case "authenticating": return "正在加密认证…"
        case "retrying":       return "未扫到设备（等待自动重试）"
        default:               return "准备连接蓝牙…"
        }
    }
}
