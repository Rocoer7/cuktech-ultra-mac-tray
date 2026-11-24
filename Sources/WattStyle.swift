import AppKit
import SwiftUI

/// 功率数字的取色与格式化（对齐 cuktech-ultra-tray/WattStyle.cs，并针对 macOS 深浅色菜单栏做了对比度适配）
enum WattStyle {
    enum Tier {
        case dim
        case cool
        case ok
        case warn
        case bad
    }

    /// 总功率五档（120W 满载分档）：空载灰 / <20W 淡蓝 / 20~60W 绿 / 60~100W 黄 / >=100W 红
    static func totalTier(_ watts: Double, connected: Bool = true) -> Tier {
        guard connected else { return .dim }
        if watts >= 100 { return .bad }
        if watts >= 60 { return .warn }
        if watts >= 20 { return .ok }
        if watts > 0.05 { return .cool }
        return .dim
    }

    /// 单口功率五档：空载灰 / <20W 淡蓝 / 20~40W 绿 / 40~80W 黄 / >=80W 红
    static func portTier(_ watts: Double, active: Bool = true) -> Tier {
        guard active else { return .dim }
        if watts >= 80 { return .bad }
        if watts >= 40 { return .warn }
        if watts >= 20 { return .ok }
        if watts > 0.05 { return .cool }
        return .dim
    }

    /// 深色面板内使用的标准色（与 cuktech-ultra-tray 逐通道一致）
    static func panelColor(for tier: Tier) -> Color {
        switch tier {
        case .dim:  return Color(red: 154 / 255, green: 160 / 255, blue: 166 / 255)
        case .cool: return Color(red: 125 / 255, green: 211 / 255, blue: 252 / 255)
        case .ok:   return Color(red: 52 / 255,  green: 211 / 255, blue: 153 / 255)
        case .warn: return Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
        case .bad:  return Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
        }
    }

    /// 顶部菜单栏文字颜色（利用动态 NSColor 自动适配浅色壁纸黑字模式与深色壁纸白字模式）
    static func statusBarNSColor(for tier: Tier) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua]) != .aqua
            switch tier {
            case .dim:
                return isDark
                    ? NSColor(srgbRed: 168 / 255, green: 174 / 255, blue: 182 / 255, alpha: 0.92)
                    : NSColor(srgbRed: 95 / 255,  green: 102 / 255, blue: 110 / 255, alpha: 0.92)
            case .cool:
                return isDark
                    ? NSColor(srgbRed: 125 / 255, green: 211 / 255, blue: 252 / 255, alpha: 1.0)
                    : NSColor(srgbRed: 2 / 255,   green: 119 / 255, blue: 189 / 255, alpha: 1.0)
            case .ok:
                return isDark
                    ? NSColor(srgbRed: 52 / 255,  green: 211 / 255, blue: 153 / 255, alpha: 1.0)
                    : NSColor(srgbRed: 5 / 255,   green: 135 / 255, blue: 90 / 255,  alpha: 1.0)
            case .warn:
                return isDark
                    ? NSColor(srgbRed: 251 / 255, green: 191 / 255, blue: 36 / 255,  alpha: 1.0)
                    : NSColor(srgbRed: 194 / 255, green: 110 / 255, blue: 0 / 255,   alpha: 1.0)
            case .bad:
                return isDark
                    ? NSColor(srgbRed: 248 / 255, green: 113 / 255, blue: 113 / 255, alpha: 1.0)
                    : NSColor(srgbRed: 211 / 255, green: 47 / 255,  blue: 47 / 255,  alpha: 1.0)
            }
        }
    }

    /// 功率格式化：100W 及以上省略小数，其余保留 1 位小数
    static func formatWatts(_ watts: Double) -> String {
        let clamped = max(0, watts)
        if clamped >= 100 {
            return String(format: "%.0f", clamped)
        }
        return String(format: "%.1f", clamped)
    }
}
