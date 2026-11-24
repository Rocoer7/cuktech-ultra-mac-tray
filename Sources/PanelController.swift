import AppKit
import SwiftUI

/// 无边框浮动面板窗口（支持 Esc 收起、失焦自动收起与图钉固定桌面位置记忆）
final class FloatingPanelWindow: NSPanel {
    var onEscapePressed: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscapePressed?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: Smart10uStore
    private let panel: FloatingPanelWindow
    private var globalClickMonitor: Any?

    private static let posXKey = "CuktechMacTray.PanelX"
    private static let posYKey = "CuktechMacTray.PanelY"
    private static let hasSavedPosKey = "CuktechMacTray.HasSavedPos"

    init(store: Smart10uStore, onRequestQuit: @escaping () -> Void) {
        self.store = store

        let panel = FloatingPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 344, height: 390),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingController(rootView: PanelView(store: store, onRequestQuit: onRequestQuit))
        panel.contentViewController = hosting
        self.panel = panel

        super.init()

        panel.delegate = self
        panel.onEscapePressed = { [weak self] in
            guard let self else { return }
            if !self.store.isPinned {
                self.hide()
            }
        }
        applyPinBehavior(isPinned: store.isPinned)
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggle(relativeTo statusButton: NSStatusBarButton?) {
        if panel.isVisible {
            if store.isPinned {
                // 已固定在桌面上时，再次点击状态栏图标把它带到最前；若已在最前则收起
                if panel.isKeyWindow {
                    hide()
                } else {
                    panel.makeKeyAndOrderFront(nil)
                }
            } else {
                hide()
            }
        } else {
            show(relativeTo: statusButton)
        }
    }

    func show(relativeTo statusButton: NSStatusBarButton?, selectTab: PanelTab? = nil) {
        if let selectTab {
            store.selectedTab = selectTab
            if selectTab != .read {
                Task { await store.refreshStatus() }
            }
        }

        panel.contentView?.layoutSubtreeIfNeeded()
        if let fitting = panel.contentView?.fittingSize, fitting.height > 100 {
            panel.setContentSize(fitting)
        }

        positionPanel(relativeTo: statusButton)
        applyPinBehavior(isPinned: store.isPinned)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitorIfNeeded()
    }

    func hide() {
        removeOutsideClickMonitor()
        panel.orderOut(nil)
    }

    func applyPinBehavior(isPinned: Bool) {
        // 对齐 cuktech-ultra-tray：固定到桌面后不强压普通窗口置顶（使用 normal 层级），且允许拖拽背景移动记住位置；
        // 未固定时作为状态栏弹出层（popUpMenu / statusBar 层级），点外部自动收起。
        if isPinned {
            panel.level = .normal
            panel.isMovableByWindowBackground = true
            removeOutsideClickMonitor()
        } else {
            panel.level = .statusBar
            panel.isMovableByWindowBackground = false
            if panel.isVisible {
                installOutsideClickMonitorIfNeeded()
            }
        }
    }

    // MARK: - 定位与位置记忆

    private func positionPanel(relativeTo button: NSStatusBarButton?) {
        let defaults = UserDefaults.standard
        if store.isPinned, defaults.bool(forKey: Self.hasSavedPosKey) {
            let x = defaults.double(forKey: Self.posXKey)
            let y = defaults.double(forKey: Self.posYKey)
            let candidate = NSRect(origin: NSPoint(x: x, y: y), size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                panel.setFrameOrigin(candidate.origin)
                return
            }
        }

        if let button, let btnWindow = button.window {
            let btnRectInWindow = button.convert(button.bounds, to: nil)
            let btnRectOnScreen = btnWindow.convertToScreen(btnRectInWindow)
            let screen = btnWindow.screen ?? NSScreen.main ?? NSScreen.screens.first

            let panelSize = panel.frame.size
            var x = round(btnRectOnScreen.midX - panelSize.width / 2)
            var y = round(btnRectOnScreen.minY - panelSize.height - 6)

            if let visible = screen?.visibleFrame {
                x = max(visible.minX + 8, min(x, visible.maxX - panelSize.width - 8))
                y = max(visible.minY + 8, y)
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let x = round(visible.maxX - panel.frame.width - 20)
            let y = round(visible.maxY - panel.frame.height - 16)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard store.isPinned else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set(origin.x, forKey: Self.posXKey)
        UserDefaults.standard.set(origin.y, forKey: Self.posYKey)
        UserDefaults.standard.set(true, forKey: Self.hasSavedPosKey)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !store.isPinned && store.pairState == .hidden {
            hide()
        }
    }

    // MARK: - 点击外部自动收起

    private func installOutsideClickMonitorIfNeeded() {
        guard !store.isPinned, globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.store.isPinned, self.store.pairState == .hidden else { return }
                self.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}
