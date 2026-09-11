//
//  CombinedView.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 09/01/2023
//  Using Swift 5.0
//  Running on macOS 13.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class CombinedView: NSObject, NSGestureRecognizerDelegate {
    private var menuBarItem: NSStatusItem? = nil
    private var view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: Constants.Widget.height))
    private var popup: PopupWindow? = nil
    private var powerTimer: Timer? = nil
    private var popupVisible: Bool = false

    private var status: Bool {
        Store.shared.bool(key: "CombinedModules", defaultValue: false)
    }
    // when enabled, the menu bar shows a single fixed icon instead of inline widgets
    private var singleIcon: Bool {
        Store.shared.bool(key: "CombinedModules_icon", defaultValue: false)
    }
    private var spacing: CGFloat {
        CGFloat(Int(Store.shared.string(key: "CombinedModules_spacing", defaultValue: "")) ?? 0)
    }
    private var separator: Bool {
        Store.shared.bool(key: "CombinedModules_separator", defaultValue: false)
    }
    
    private var activeModules: [Module] {
        modules.filter({ $0.enabled }).sorted(by: { $0.combinedPosition < $1.combinedPosition })
    }
    
    private var combinedModulesPopup: Bool {
        get { Store.shared.bool(key: "CombinedModules_popup", defaultValue: true) }
        set { Store.shared.set(key: "CombinedModules_popup", value: newValue) }
    }
    
    override init() {
        super.init()
        
        modules.forEach { (m: Module) in
            m.menuBar.callback = { [weak self] in
                if let s = self?.status, s {
                    DispatchQueue.main.async(execute: {
                        self?.recalculate()
                    })
                }
            }
        }
        
        self.popup = PopupWindow(title: localizedString("System Overview"), module: .combined, view: Popup()) { [weak self] state in
            self?.popupVisible = state
            if !state {
                self?.refreshPowerIcon()
                // debug capture mode: the panel closes as soon as the
                // shell-launched agent resigns key, so keep re-opening it
                // while the flag is active
                if CommandLine.arguments.contains("--debug-open-popup") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, !(self.popup?.isVisible ?? false), let button = self.menuBarItem?.button else { return }
                        self.togglePopup(button)
                    }
                }
            }
        }
        
        if self.status {
            self.enable()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForOneView), name: .toggleOneView, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForModuleRearrrange), name: .moduleRearrange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenCombinedModulesPopup), name: .combinedModulesPopup, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForModule), name: .toggleModule, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .toggleOneView, object: nil)
        NotificationCenter.default.removeObserver(self, name: .moduleRearrange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .combinedModulesPopup, object: nil)
        NotificationCenter.default.removeObserver(self, name: .toggleModule, object: nil)
    }
    
    public func enable() {
        if let old = self.menuBarItem {
            NSStatusBar.system.removeStatusItem(old)
        }
        self.menuBarItem = NSStatusBar.system.statusItem(withLength: 0)
        DispatchQueue.main.async(execute: {
            self.menuBarItem?.autosaveName = "CombinedModules"
        })
        self.menuBarItem?.button?.toolTip = localizedString("Combined modules")

        // debug/CI helper: `Stats --debug-open-popup` opens the combined
        // overview right after launch so it can be captured headlessly
        // (screencapture -l) without Accessibility-driven clicks. Must run in
        // BOTH modes — single-icon mode returns early below.
        if CommandLine.arguments.contains("--debug-open-popup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let button = self.menuBarItem?.button else { return }
                self.togglePopup(button)
            }
        }

        // single icon mode: show a live power mini-widget when Sensors is enabled,
        // otherwise fall back to the fixed gauge icon.
        if self.singleIcon {
            self.setupSingleIconView()
            self.activeModules.forEach { $0.menuBar.disable() }
            return
        }

        self.menuBarItem?.button?.addSubview(self.view)
        self.menuBarItem?.button?.image = NSImage()

        if !self.combinedModulesPopup {
            self.activeModules.forEach { (m: Module) in
                m.menuBar.widgets.forEach { w in
                    w.item.onClick = {
                        if let window = w.item.window {
                            NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
                                "module": m.name,
                                "widget": w.type,
                                "origin": window.frame.origin,
                                "center": window.frame.width/2
                            ])
                        }
                    }
                }
            }
        } else {
            self.menuBarItem?.button?.target = self
            self.menuBarItem?.button?.action = #selector(self.togglePopup)
            self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        
        DispatchQueue.main.async(execute: {
            self.recalculate()
        })
    }
    
    public func disable() {
        self.activeModules.forEach { (m: Module) in
            m.menuBar.widgets.forEach { w in
                w.item.onClick = nil
            }
        }
        self.powerTimer?.invalidate()
        self.powerTimer = nil
        if let item = self.menuBarItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.menuBarItem = nil
    }

    private func setupSingleIconView() {
        guard let portal = self.powerPortal(), portal.lastPowerValue != nil else {
            self.menuBarItem?.button?.image = self.icon()
            self.menuBarItem?.length = 30
            self.menuBarItem?.button?.target = self
            self.menuBarItem?.button?.action = #selector(self.togglePopup)
            self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
            return
        }

        self.menuBarItem?.length = 36
        self.menuBarItem?.button?.target = self
        self.menuBarItem?.button?.action = #selector(self.togglePopup)
        self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])

        self.refreshPowerIcon()
        self.powerTimer?.invalidate()
        self.powerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshPowerIcon()
        }
    }

    private var lastPowerImageText: String = ""

    private func refreshPowerIcon() {
        guard let portal = self.powerPortal(), let value = portal.lastPowerValue else {
            self.menuBarItem?.button?.image = self.icon()
            return
        }
        let displayValue = value * 100
        let text = "\(Int(displayValue.rounded()))\(portal.lastPowerUnit ?? "W")"
        guard text != self.lastPowerImageText else { return }
        self.lastPowerImageText = text
        let image = self.powerImage(value: displayValue, unit: portal.lastPowerUnit ?? "W")
        // template images get an implicit cross-fade on NSStatusBarButton;
        // disable it so updates are instant instead of visibly lagging
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.menuBarItem?.button?.image = image
        CATransaction.commit()
    }

    private func powerImage(value: Double, unit: String) -> NSImage {
        let text = "\(Int(value.rounded()))\(unit)"
        let size = NSSize(width: 36, height: Constants.Widget.height)
        let image = NSImage(size: size)
        // warning colors are baked in; normal state renders as a template mask
        // so the menu bar tints it to match the actual backdrop (light/dark)
        let warningColor = self.color(for: value)
        image.lockFocus()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: warningColor ?? NSColor.black
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let point = NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2)
        str.draw(at: point)
        image.unlockFocus()
        image.isTemplate = warningColor == nil
        return image
    }

    private func color(for value: Double) -> NSColor? {
        if value >= 50 { return NSColor.systemRed }
        if value >= 25 { return NSColor.systemOrange }
        return nil
    }

    private func powerPortal() -> CombinedSensorsPortal? {
        guard let m = modules.first(where: { $0.name == "Sensors" && $0.enabled }) else { return nil }
        return m.portal as? CombinedSensorsPortal
    }

    private func icon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        for name in ["gauge.with.dots.needle.bottom.50percent", "gauge", "chart.bar.xaxis"] {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Stats")?.withSymbolConfiguration(config) {
                img.isTemplate = true
                return img
            }
        }
        return NSImage()
    }

    private func recalculate() {
        guard !self.singleIcon else { return }
        self.view.subviews.forEach({ $0.removeFromSuperview() })

        let visibleModules = self.activeModules.filter({ !$0.menuBar.activeWidgets.isEmpty })
        var w: CGFloat = 0
        visibleModules.enumerated().forEach { (i, m) in
            if i != 0 {
                w += self.spacing
                if self.separator {
                    let separator = NSView(frame: NSRect(x: w, y: 3, width: 1, height: Constants.Widget.height-6))
                    separator.wantsLayer = true
                    separator.layer?.backgroundColor = (separator.isDarkMode ? NSColor.white : NSColor.black).cgColor
                    self.view.addSubview(separator)
                    w += 3 + self.spacing
                }
            }
            self.view.addSubview(m.menuBar.view)
            m.menuBar.view.setFrameOrigin(NSPoint(x: w, y: 0))
            w += m.menuBar.view.frame.width
        }
        self.view.setFrameSize(NSSize(width: w, height: self.view.frame.height))
        self.menuBarItem?.length = w
    }
    
    @objc private func togglePopup(_ sender: NSButton) {
        guard let popup = self.popup, let item = self.menuBarItem, let window = item.button?.window else { return }

        // Clicking the status item while the popup is open first makes the
        // popup resign key, then delivers this button action. In that event
        // order, the resign handler already closed it; do not reopen it.
        if popup.consumeRecentResignDismissal() {
            return
        }

        let openedWindows = NSApplication.shared.windows.filter{ $0 is NSPanel }
        openedWindows.forEach{ $0.setIsVisible(false) }

        if !popup.isVisible {
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            popup.contentView?.invalidateIntrinsicContentSize()
            
            let windowCenter = popup.contentView!.intrinsicContentSize.width / 2
            var x = window.frame.origin.x - windowCenter + window.frame.width/2
            let y = window.frame.origin.y - popup.contentView!.intrinsicContentSize.height - 3
            
            let buttonPoint = NSPoint(x: window.frame.midX, y: window.frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonPoint) }) ?? NSScreen.main {
                if x + popup.contentView!.intrinsicContentSize.width > screen.frame.maxX {
                    x = screen.frame.maxX - popup.contentView!.intrinsicContentSize.width - 3
                }
                if x < screen.frame.minX {
                    x = screen.frame.minX + 3
                }
            }
            
            popup.setFrameOrigin(NSPoint(x: x, y: y))
            popup.makeKeyAndOrderFront(nil)
            self.popupVisible = true
        } else {
            popup.orderOut(nil)
            self.popupVisible = false
        }
    }
    
    @objc private func listenForOneView(_ notification: Notification) {
        guard notification.userInfo?["module"] == nil else { return }
        
        if self.status {
            self.enable()
        } else {
            self.disable()
        }
    }
    
    @objc private func listenForModuleRearrrange() {
        self.recalculate()
    }
    
    @objc private func listenCombinedModulesPopup() {
        if !self.combinedModulesPopup {
            self.activeModules.forEach { (m: Module) in
                m.menuBar.widgets.forEach { w in
                    w.item.onClick = {
                        if let window = w.item.window {
                            NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
                                "module": m.name,
                                "widget": w.type,
                                "origin": window.frame.origin,
                                "center": window.frame.width/2
                            ])
                        }
                    }
                }
            }
            self.menuBarItem?.button?.action = nil
        } else {
            self.activeModules.forEach { (m: Module) in
                m.menuBar.widgets.forEach { w in
                    w.item.onClick = nil
                }
            }
            
            self.menuBarItem?.button?.target = self
            self.menuBarItem?.button?.action = #selector(self.togglePopup)
            self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }
    
    @objc private func listenForModule(_ notification: Notification) {
        guard let name = notification.userInfo?["module"] as? String,
              let state = notification.userInfo?["state"] as? Bool,
              state,
              let module = self.activeModules.first(where: { $0.name == name }) else { return }
        
        if self.singleIcon {
            module.menuBar.disable()
        } else {
            module.menuBar.widgets.forEach { w in
                w.item.onClick = {
                    if let window = w.item.window {
                        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
                            "module": module.name,
                            "widget": w.type,
                            "origin": window.frame.origin,
                            "center": window.frame.width/2
                        ])
                    }
                }
            }
        }
    }
}

// MARK: - Overview popup

private class Popup: NSStackView, Popup_p {
    fileprivate var keyboardShortcut: [UInt16] = []
    fileprivate var sizeCallback: ((NSSize) -> Void)? = nil

    private let power: PowerFlowPortal = PowerFlowPortal()
    private let tiles: MetricTilesGrid = MetricTilesGrid()
    private let calendar: CalendarPortal = CalendarPortal()
    private let proxy: ProxyPortal = ProxyPortal()
    private let kimi: KimiServerControl = KimiServerControl()
    private let infoStrip: InfoStrip = InfoStrip()
    private let clockCard: ClockCard = ClockCard()
    private var refreshTimer: Timer?

    init() {
        self.keyboardShortcut = Store.shared.array(key: "CombinedModules_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []

        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = 0

        self.power.onResize = { [weak self] in
            self?.recomputeHeight()
        }
        self.proxy.onResize = { [weak self] in
            guard let self = self else { return }
            self.proxy.isHidden = !self.proxy.reachable
            self.recomputeHeight()
        }

        self.reinit()

        NotificationCenter.default.addObserver(self, selector: #selector(reinit), name: .toggleModule, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reinit), name: .toggleOneView, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    fileprivate func settings() -> NSView? { return nil }
    fileprivate func appear() {
        self.tiles.refresh()
        self.calendar.refresh()
        self.infoStrip.requestQuotaRefresh()
        self.infoStrip.refresh()
        self.clockCard.refresh()
        self.kimi.refresh()
        self.refreshTimer?.invalidate()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tiles.refresh()
            self?.calendar.refresh()
            self?.infoStrip.refresh()
            self?.clockCard.refresh()
        }
        self.power.start()
        self.proxy.start()
    }
    fileprivate func disappear() {
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        self.power.stop()
        self.proxy.stop()
    }
    fileprivate func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "CombinedModules_popup_keyboardShortcut", value: binding)
    }

    // modules whose data is shown by the unified cards (hero + tiles + clock row),
    // so their stock portals are not added to the panel
    static private let coveredModules: [String] = ["CPU", "GPU", "RAM", "Disk", "Network", "Sensors", "Battery", "Clock"]

    @objc private func reinit() {
        self.subviews.forEach({ $0.removeFromSuperview() })

        let spacing = Design.gap
        let dashboard = Store.shared.bool(key: "CombinedModules_icon", defaultValue: false)
        let columns = dashboard ? 3 : 2
        let columnWidth: CGFloat = dashboard ? 316 : Constants.Popup.width
        let width = CGFloat(columns) * columnWidth + CGFloat(columns - 1) * spacing

        self.spacing = spacing

        // Quota + clock bindings
        if let q = modules.first(where: { $0.name == "Quota" && $0.enabled })?.portal as? CombinedQuotaPortal {
            self.infoStrip.bindQuota(q)
        } else {
            self.infoStrip.unbindQuota()
        }
        if let c = modules.first(where: { $0.name == "Clock" && $0.enabled })?.portal as? CombinedClockPortal {
            self.clockCard.bind(c)
        }
        self.infoStrip.refresh()
        self.clockCard.refresh()

        if dashboard {
            self.addArrangedSubview(self.topBar(width: width))

            self.tiles.rebuild(width: width, gap: spacing)
            if !self.tiles.isEmpty {
                self.tiles.refresh()
                self.addArrangedSubview(self.tiles)
            }

            // Row 2: energy — the power hero beside the world clock. Both
            // cards carry their own 118pt height, so the row reads as a pair.
            self.power.setWidth(648)
            self.power.isHidden = !self.power.available
            self.clockCard.setWidth(self.power.available ? width - spacing - 648 : width)
            let energy = NSStackView(views: [self.power, self.clockCard])
            energy.orientation = .horizontal
            energy.alignment = .top
            energy.spacing = spacing
            self.addArrangedSubview(energy)

            // Row 3: time & capacity — the calendar beside the 2x2 quota
            // grid; the quota card follows the calendar height so the row
            // stays flush (single source: contextHeight).
            self.calendar.setSize(width: 369, height: nil)
            self.calendar.refresh()
            let contextHeight = max(self.calendar.fittingSize.height, 268)
            self.calendar.setSize(width: 369, height: contextHeight)
            self.infoStrip.setWidth(width - spacing - 369, sidebar: true,
                                    height: contextHeight, clockVisible: false)
            let context = NSStackView(views: [self.calendar, self.infoStrip])
            context.orientation = .horizontal
            context.alignment = .top
            context.spacing = spacing
            self.addArrangedSubview(context)

            // Row 4: network — the proxy card keeps the full width
            self.proxy.setWidth(width)
            self.proxy.isHidden = !self.proxy.reachable
            self.addArrangedSubview(self.proxy)
        } else {
            // Classic (non-dashboard) layout: keep the original compact arrangement
            self.power.setWidth(width)
            self.power.isHidden = !self.power.available
            self.addArrangedSubview(self.power)

            self.tiles.rebuild(width: width)
            if !self.tiles.isEmpty {
                self.tiles.refresh()
                self.addArrangedSubview(self.tiles)
            }

            let fallback: [Portal_p] = modules
                .filter({ $0.enabled && $0.portal != nil && !Popup.coveredModules.contains($0.name) && $0.name != "Quota" })
                .compactMap({ $0.portal })
            if !fallback.isEmpty {
                let grid = NSGridView()
                grid.rowSpacing = spacing
                grid.columnSpacing = spacing
                var row: [NSView] = []
                fallback.forEach { p in
                    row.append(p)
                    if row.count == columns {
                        grid.addRow(with: row)
                        row = []
                    }
                }
                if !row.isEmpty {
                    while row.count < columns { row.append(NSView()) }
                    grid.addRow(with: row)
                }
                for i in 0..<columns {
                    grid.column(at: i).width = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
                    grid.column(at: i).xPlacement = .fill
                }
                for r in 0..<grid.numberOfRows {
                    grid.row(at: r).height = Constants.Popup.portalHeight
                    grid.row(at: r).yPlacement = .fill
                }
                self.addArrangedSubview(grid)
            }

            self.infoStrip.setWidth(width, sidebar: false, height: InfoStrip.compactHeight, clockVisible: true)
            self.addArrangedSubview(self.infoStrip)
            self.calendar.setSize(width: width, height: nil)
            self.calendar.refresh()
            self.addArrangedSubview(self.calendar)

            self.proxy.setWidth(width)
            self.proxy.isHidden = !self.proxy.reachable
            self.addArrangedSubview(self.proxy)
        }

        self.applySize(width: width)

        // Capture layout diagnostics only for an explicit preview run.
        guard CommandLine.arguments.contains("--debug-open-popup") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            func visit(_ v: NSView, depth: Int) -> String {
                let indent = String(repeating: "  ", count: depth)
                let f = v.frame
                let hidden = v.isHidden ? " [HIDDEN]" : ""
                let cls = String(describing: type(of: v))
                var s = "\(indent)\(cls) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width))x\(Int(f.size.height)))\(hidden)\n"
                for sub in v.subviews { s += visit(sub, depth: depth + 1) }
                return s
            }
            try? visit(self, depth: 0).write(toFile: "/tmp/stats_hierarchy.txt", atomically: true, encoding: .utf8)
        }
    }

    private func topBar(width: CGFloat) -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 12)
        bar.wantsLayer = true
        bar.applyCardStyle()
        bar.widthAnchor.constraint(equalToConstant: width).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let title = NSTextField(labelWithString: localizedString("Dashboard overview"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        for view in [title, NSView(), self.kimi] { bar.addArrangedSubview(view) }
        return bar
    }

    // size the stack to its real (constraint-driven) height so nothing gets compressed
    private func applySize(width: CGFloat) {
        self.layoutSubtreeIfNeeded()
        let height = self.fittingSize.height
        self.setFrameSize(NSSize(width: width, height: height))
        self.sizeCallback?(NSSize(width: width, height: height))
    }

    private func recomputeHeight() {
        self.applySize(width: self.frame.width)
    }
}

// MARK: - Info strip (Quota + Clock merged)

// One horizontal card: the left ~46% shows the Quota provider rows (one row
// per source — Kimi / Codex / Go — each with 5h/周/月 window slots aligned in
// columns; rows appear only while the API reports their windows), the right
// side shows the world clock row. Merges the former two separate cards into
// a single line family; strip height follows the visible row count so the
// data can never clip.
private class InfoStrip: NSStackView {
    static let compactHeight: CGFloat = 62

    private var quotaSource: CombinedQuotaPortal?
    private var providerRows: [QuotaProviderRow] = []
    private var quotaGroups: [QuotaGroupView] = []
    private var groupedBox: NSStackView?
    private var quotaBox: NSStackView?
    private var quotaSection: NSStackView?
    private var quotaHeader: NSView?
    private var quotaHeaderHeight: NSLayoutConstraint?
    private var quotaColumnHeader: NSStackView?
    private var quotaWidthConstraint: NSLayoutConstraint?
    private var gridWidths: [NSLayoutConstraint] = []
    private var clockWidthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var sidebarMode: Bool = false
    // when false, the clock section is suppressed entirely (dashboard mode
    // renders clocks in a dedicated ClockCard beside the PowerFlow hero)
    private var clockVisible: Bool = true

    private var clockEntries: [(name: NSTextField, time: NSTextField, delta: NSTextField)] = []
    private var clockNames: [String] = []
    private var clockBox: NSStackView?
    private var latestReadings: [ClockReading] = []

    init() {
        super.init(frame: .zero)

        self.wantsLayer = true
        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fill
        self.spacing = 10
        self.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: InfoStrip.compactHeight)
        self.heightConstraint?.isActive = true

        // left: Quota (fixed share)
        let quotaSection = NSStackView()
        quotaSection.orientation = .vertical
        quotaSection.alignment = .width
        quotaSection.spacing = 8
        quotaSection.edgeInsets = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)
        quotaSection.wantsLayer = true
        quotaSection.applyCardStyle()
        quotaSection.setContentHuggingPriority(.required, for: .vertical)
        quotaSection.setContentCompressionResistancePriority(.required, for: .vertical)

        let quotaHeader = NSStackView()
        quotaHeader.orientation = .horizontal
        quotaHeader.alignment = .centerY
        quotaHeader.spacing = 5
        self.quotaHeaderHeight = quotaHeader.heightAnchor.constraint(equalToConstant: 18)
        self.quotaHeaderHeight?.isActive = true
        quotaHeader.setContentCompressionResistancePriority(.required, for: .vertical)
        let quotaIcon = NSImageView()
        quotaIcon.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
        quotaIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        quotaIcon.contentTintColor = .systemGreen
        let quotaLabel = NSTextField(labelWithString: localizedString("Overview remaining quota"))
        quotaLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        quotaLabel.textColor = Design.secondaryTextColor
        quotaHeader.addArrangedSubview(quotaIcon)
        quotaHeader.addArrangedSubview(quotaLabel)
        quotaHeader.addArrangedSubview(NSView())
        quotaSection.addArrangedSubview(quotaHeader)

        // The progress bars are a three-window comparison, rather than three
        // anonymous meters. Keeping the window names in a dedicated header
        // makes a quick glance answer both "how much" and "which limit".
        let quotaColumnHeader = NSStackView()
        quotaColumnHeader.orientation = .horizontal
        quotaColumnHeader.alignment = .centerY
        quotaColumnHeader.distribution = .fill
        quotaColumnHeader.spacing = 8
        let providerSpacer = NSView()
        providerSpacer.widthAnchor.constraint(equalToConstant: QuotaProviderRow.labelWidth).isActive = true
        quotaColumnHeader.addArrangedSubview(providerSpacer)

        let windowHeader = NSStackView()
        windowHeader.orientation = .horizontal
        windowHeader.alignment = .centerY
        windowHeader.distribution = .fillEqually
        windowHeader.spacing = 8
        windowHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for title in [localizedString("Quota window short"), localizedString("Quota window week"), localizedString("Quota window month")] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 9, weight: .medium)
            label.textColor = Design.mutedTextColor
            label.alignment = .center
            windowHeader.addArrangedSubview(label)
        }
        quotaColumnHeader.addArrangedSubview(windowHeader)
        quotaSection.addArrangedSubview(quotaColumnHeader)

        let q = NSStackView()
        q.orientation = .vertical
        q.alignment = .width
        q.spacing = 4
        // One row per PROVIDER, not per window: with three sources × up to
        // three windows, a per-window grid grew to 7 cells and clipped inside
        // the fixed-height strip. A provider row keeps three equal window
        // slots (5h / 周 / 月) so columns stay aligned across rows, and the
        // row count is bounded by the number of providers, not windows.
        // Codex and Go rows are created up front but stay hidden until the
        // API actually reports their windows — the row set follows whatever
        // comes back (OpenAI has retired and restored windows before).
        for provider in QuotaProvider.allCases {
            let row = QuotaProviderRow(provider: provider)
            self.providerRows.append(row)
            q.addArrangedSubview(row)
        }
        quotaSection.addArrangedSubview(q)
        // Dashboard layout: two rows of two provider blocks — the proven
        // grid pattern (explicit equal widths & heights; fillEqually degrades
        // when content demands more width, so widths are pinned instead).
        // Kimi 1 / Kimi 2 on the first row, Codex / Go on the second.
        let windowTitles = [
            localizedString("Quota window short"),
            localizedString("Quota window week"),
            localizedString("Quota window month")
        ]
        for provider in QuotaProvider.allCases {
            let titles = provider == .openCode ? windowTitles : Array(windowTitles.prefix(2))
            self.quotaGroups.append(QuotaGroupView(providerLabel: provider.label, windowTitles: titles))
        }
        func makeRow(_ pair: [QuotaGroupView]) -> NSStackView {
            let row = NSStackView(views: pair)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fill
            row.spacing = 26
            return row
        }
        let gridBox = NSStackView(views: [
            makeRow([self.quotaGroups[0], self.quotaGroups[1]]),
            makeRow([self.quotaGroups[2], self.quotaGroups[3]])
        ])
        gridBox.orientation = .vertical
        gridBox.alignment = .width
        gridBox.distribution = .fill
        gridBox.spacing = 8
        // every block shares the top-left block's width & height (assigned in
        // setWidth); the grid itself is pinned to the card content width
        for group in self.quotaGroups.dropFirst() {
            group.widthAnchor.constraint(equalTo: self.quotaGroups[0].widthAnchor).isActive = true
            group.heightAnchor.constraint(equalTo: self.quotaGroups[0].heightAnchor).isActive = true
        }
        gridBox.isHidden = true
        quotaSection.addArrangedSubview(gridBox)
        self.groupedBox = gridBox

        // tall sidebar mode: let the leftover height pool at the bottom instead
        // of stretching a random internal view (distribution .fill otherwise
        // inflates the last arranged subview)
        quotaSection.addArrangedSubview(NSView())
        quotaColumnHeader.widthAnchor.constraint(equalTo: q.widthAnchor).isActive = true
        self.addArrangedSubview(quotaSection)
        self.quotaBox = q
        self.quotaSection = quotaSection
        self.quotaHeader = quotaHeader
        self.quotaColumnHeader = quotaColumnHeader

        // right: Clock (remaining width)
        let c = NSStackView()
        c.orientation = .horizontal
        c.alignment = .centerY
        c.distribution = .fill
        c.spacing = 9
        c.edgeInsets = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)
        c.wantsLayer = true
        c.applyCardStyle()
        self.addArrangedSubview(c)
        self.clockBox = c

        let click = NSClickGestureRecognizer(target: self, action: #selector(self.openQuotaPopup))
        quotaSection.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not implemented")
    }

    public override func updateLayer() {
        self.quotaSection?.applyCardStyle()
        self.clockBox?.applyCardStyle()
    }

    // set after the strip is in the popup tree and its width is known; using a
    // constant (not a multiplier on self.widthAnchor) avoids the mutually-
    // exclusive Auto Layout constraint that fires during init
    internal func setWidth(_ width: CGFloat, sidebar: Bool, height: CGFloat, clockVisible: Bool = true) {
        self.sidebarMode = sidebar
        self.clockVisible = clockVisible
        self.orientation = sidebar ? .vertical : .horizontal
        self.alignment = sidebar ? .width : .centerY
        self.spacing = sidebar ? Design.gap : 10
        self.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        self.heightConstraint?.constant = height
        self.quotaHeaderHeight?.constant = sidebar ? 24 : 18
        self.quotaHeader?.isHidden = !sidebar
        // the 5h/周/月 column header belongs to the compact column grid; the
        // dashboard uses the per-provider grouped list instead
        self.quotaColumnHeader?.isHidden = sidebar
        self.quotaBox?.isHidden = sidebar
        self.groupedBox?.isHidden = !sidebar
        self.quotaSection?.spacing = sidebar ? 6 : 8
        self.quotaSection?.edgeInsets = sidebar
            ? NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)
            : NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        self.clockBox?.edgeInsets = sidebar
            ? NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)
            : NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)

        self.quotaWidthConstraint?.isActive = false
        self.clockWidthConstraint?.isActive = false
        self.quotaWidthConstraint = nil
        self.clockWidthConstraint = nil
        if sidebar {
            self.quotaWidthConstraint = self.quotaSection?.widthAnchor.constraint(equalToConstant: width)
            self.clockWidthConstraint = self.clockBox?.widthAnchor.constraint(equalToConstant: width)
            self.quotaWidthConstraint?.isActive = true
            self.clockWidthConstraint?.isActive = true
            // 2x2 grid geometry: the card height drives the block height
            // (grid = height − 58 → 22 insets + 24 header + two 6pt spacings;
            // rows = grid − 8), so a provider row-count change can never clip.
            let contentWidth = width - 26
            let columnWidth = (contentWidth - 26) / 2
            let gridHeight = height - 58
            let rowHeight = (gridHeight - 8) / 2
            self.gridWidths.forEach { $0.isActive = false }
            self.gridWidths = []
            if let box = self.groupedBox, let first = self.quotaGroups.first {
                self.gridWidths = [
                    box.widthAnchor.constraint(equalToConstant: contentWidth),
                    box.heightAnchor.constraint(equalToConstant: gridHeight),
                    first.widthAnchor.constraint(equalToConstant: columnWidth),
                    first.heightAnchor.constraint(equalToConstant: rowHeight),
                ]
            }
            self.gridWidths.forEach { $0.isActive = true }
        } else {
            self.quotaWidthConstraint = self.quotaSection?.widthAnchor.constraint(equalToConstant: width * 0.46)
            self.quotaWidthConstraint?.isActive = true
        }
        self.quotaBox?.orientation = sidebar ? .vertical : .vertical
        self.quotaBox?.alignment = .width
        self.quotaBox?.distribution = .fill
        self.quotaBox?.spacing = sidebar ? 12 : 4
        self.providerRows.forEach { $0.configure(sidebar: sidebar) }
        self.clockBox?.orientation = sidebar ? .vertical : .horizontal
        self.clockBox?.alignment = sidebar ? .width : .centerY
        self.clockBox?.distribution = .fill
        self.clockBox?.spacing = sidebar ? 5 : 9
        // suppress the clock section entirely when the dashboard renders clocks
        // in a dedicated card beside the PowerFlow hero
        self.clockBox?.isHidden = !clockVisible
        if clockVisible {
            self.rebuildClock(self.latestReadings)
        }
    }

    func bindQuota(_ portal: CombinedQuotaPortal?) {
        self.quotaSource = portal
    }

    func unbindQuota() {
        self.quotaSource = nil
    }

    /// Ask the Quota module for a fresh fetch. Called when the panel opens, not
    /// from the one-second timer: the module throttles it to one fetch per
    /// minute, so what the panel shows was read when it was opened.
    func requestQuotaRefresh() {
        self.quotaSource?.refreshQuota()
    }

    func refresh() {
        // quota (left)
        if let q = self.quotaSource {
            self.quotaSection?.isHidden = false
            if self.sidebarMode {
                InfoStrip.applyGrouped(quota: q, to: self.quotaGroups)
            } else {
                InfoStrip.apply(quota: q, to: self.providerRows)
            }
            // Compact strip height scales with the visible provider rows so
            // seven data points can never clip again; the sidebar (dashboard)
            // keeps its fixed tall context height managed by setWidth.
            if !self.sidebarMode {
                let visible = max(self.providerRows.filter { !$0.isHidden }.count, 1)
                self.heightConstraint?.constant = QuotaRowMetrics.stripHeight(visibleRows: visible)
            }
        } else {
            self.quotaSection?.isHidden = true
        }

        // clock (right) — suppressed entirely in dashboard mode, where the
        // dedicated ClockCard beside PowerFlow carries the clocks instead
        guard self.clockVisible else {
            self.clockBox?.isHidden = true
            return
        }
        guard let readings = InfoStrip.clockPortal()?.clockReadings, !readings.isEmpty else {
            self.clockBox?.isHidden = true
            return
        }
        self.latestReadings = readings
        self.clockBox?.isHidden = false
        if readings.map({ $0.name }) != self.clockNames {
            self.rebuildClock(readings)
        }
        for (i, r) in readings.enumerated() where i < self.clockEntries.count {
            self.clockEntries[i].time.stringValue = r.time
            self.clockEntries[i].delta.stringValue = r.dayDelta == 0 ? "" : String(format: "%+dd", r.dayDelta)
        }
    }

    private static func clockPortal() -> CombinedClockPortal? {
        guard let m = modules.first(where: { $0.name == "Clock" && $0.enabled }) else { return nil }
        return m.portal as? CombinedClockPortal
    }

    private static func apply(quota q: CombinedQuotaPortal, to rows: [QuotaProviderRow]) {
        guard rows.count == QuotaProvider.allCases.count else { return }

        // A failed poll no longer wipes the numbers: the reader hands back the
        // previous reading plus an error, and a kept value is drawn dimmed with
        // its age in the tooltip rather than as "—".
        let kimiNote = InfoStrip.staleNote(error: q.kimiError, updatedAt: q.kimiUpdatedAt)
        let codexNote = InfoStrip.staleNote(error: q.codexError, updatedAt: q.codexUpdatedAt)
        let openCodeNote = InfoStrip.staleNote(error: q.openCodeError, updatedAt: q.openCodeUpdatedAt)

        // Kimi: two windows. The weekly slot doubles as the error carrier when
        // the whole source is unavailable, so the row never collapses silently.
        rows[0].set(
            windows: [
                (pct: q.kimiFiveHourPct, resetAt: q.kimiFiveHourResetAt),
                (pct: q.kimiWeeklyPct, resetAt: q.kimiWeeklyResetAt),
                (pct: nil, resetAt: nil)
            ],
            error: q.kimiError, errorSlot: 1, note: kimiNote
        )

        let kimi2Note = InfoStrip.staleNote(error: q.kimi2Error, updatedAt: q.kimi2UpdatedAt)
        rows[1].set(
            windows: [
                (pct: q.kimi2FiveHourPct, resetAt: q.kimi2FiveHourResetAt),
                (pct: q.kimi2WeeklyPct, resetAt: q.kimi2WeeklyResetAt),
                (pct: nil, resetAt: nil)
            ],
            error: q.kimi2Error, errorSlot: 1, note: kimi2Note
        )

        // Codex: show each window the API returned; the weekly slot carries
        // the error when nothing came back.
        rows[2].set(
            windows: [
                (pct: q.codexFiveHourRemainingPct, resetAt: q.codexFiveHourResetAt),
                (pct: q.codexWeeklyRemainingPct, resetAt: q.codexWeeklyResetAt),
                (pct: nil, resetAt: nil)
            ],
            error: q.codexError, errorSlot: 1, note: codexNote
        )

        // OpenCode Go: three real windows; the monthly slot anchors the row.
        rows[3].set(
            windows: [
                (pct: q.openCodeFiveHourRemainingPct, resetAt: q.openCodeFiveHourResetAt),
                (pct: q.openCodeWeeklyRemainingPct, resetAt: q.openCodeWeeklyResetAt),
                (pct: q.openCodeMonthlyRemainingPct, resetAt: q.openCodeMonthlyResetAt)
            ],
            error: q.openCodeError, errorSlot: 2, note: openCodeNote
        )
    }

    /// Dashboard feed for the grouped list: only the windows a provider really
    /// reports are passed on, so no placeholder rows can appear.
    private static func applyGrouped(quota q: CombinedQuotaPortal, to groups: [QuotaGroupView]) {
        guard groups.count == QuotaProvider.allCases.count else { return }
        groups[0].set(windows: [
            (pct: q.kimiFiveHourPct, resetAt: q.kimiFiveHourResetAt),
            (pct: q.kimiWeeklyPct, resetAt: q.kimiWeeklyResetAt)
        ], note: InfoStrip.staleNote(error: q.kimiError, updatedAt: q.kimiUpdatedAt), error: q.kimiError)
        groups[1].set(windows: [
            (pct: q.kimi2FiveHourPct, resetAt: q.kimi2FiveHourResetAt),
            (pct: q.kimi2WeeklyPct, resetAt: q.kimi2WeeklyResetAt)
        ], note: InfoStrip.staleNote(error: q.kimi2Error, updatedAt: q.kimi2UpdatedAt), error: q.kimi2Error)
        groups[2].set(windows: [
            (pct: q.codexFiveHourRemainingPct, resetAt: q.codexFiveHourResetAt),
            (pct: q.codexWeeklyRemainingPct, resetAt: q.codexWeeklyResetAt)
        ], note: InfoStrip.staleNote(error: q.codexError, updatedAt: q.codexUpdatedAt), error: q.codexError)
        groups[3].set(windows: [
            (pct: q.openCodeFiveHourRemainingPct, resetAt: q.openCodeFiveHourResetAt),
            (pct: q.openCodeWeeklyRemainingPct, resetAt: q.openCodeWeeklyResetAt),
            (pct: q.openCodeMonthlyRemainingPct, resetAt: q.openCodeMonthlyResetAt)
        ], note: InfoStrip.staleNote(error: q.openCodeError, updatedAt: q.openCodeUpdatedAt), error: q.openCodeError)
    }

    /// Tooltip text for a value that survived a failed refresh, or nil when the
    /// value is current.
    private static func staleNote(error: String?, updatedAt: Date?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        let when = updatedAt.map { fmt.string(from: $0) } ?? "—"
        return localizedString("Quota stale", when, error)
    }

    private func rebuildClock(_ readings: [ClockReading]) {
        guard let box = self.clockBox else { return }
        box.subviews.forEach { $0.removeFromSuperview() }
        self.clockEntries = []
        self.clockNames = readings.map { $0.name }

        if self.sidebarMode {
            let title = NSStackView()
            title.orientation = .horizontal
            title.alignment = .centerY
            title.spacing = 5
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            icon.contentTintColor = .systemBlue
            let label = NSTextField(labelWithString: localizedString("World Clocks"))
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = Design.secondaryTextColor
            title.addArrangedSubview(icon)
            title.addArrangedSubview(label)
            title.addArrangedSubview(NSView())
            box.addArrangedSubview(title)
        } else {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            icon.contentTintColor = Design.mutedTextColor
            box.addArrangedSubview(icon)
        }

        for r in readings {
            let block = NSStackView()
            block.orientation = .horizontal
            block.alignment = .firstBaseline
            block.spacing = 5

            let name = NSTextField(labelWithString: r.name)
            name.font = .systemFont(ofSize: 11.5, weight: r.isLocal ? .semibold : .regular)
            name.textColor = r.isLocal ? .systemBlue : Design.secondaryTextColor
            let time = NSTextField(labelWithString: r.time)
            time.font = .monospacedDigitSystemFont(ofSize: r.isLocal ? 14 : 12.5, weight: r.isLocal ? .bold : .medium)
            time.textColor = r.isLocal ? .systemBlue : .labelColor
            let delta = NSTextField(labelWithString: "")
            delta.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
            delta.textColor = Design.secondaryTextColor
            delta.alignment = .right
            delta.widthAnchor.constraint(equalToConstant: 24).isActive = true

            block.addArrangedSubview(name)
            if self.sidebarMode {
                let localTag = NSTextField(labelWithString: localizedString("World Clock Local"))
                localTag.font = .systemFont(ofSize: 8.5, weight: .medium)
                localTag.textColor = .systemBlue
                localTag.isHidden = !r.isLocal
                block.addArrangedSubview(localTag)
                block.addArrangedSubview(NSView())
            }
            block.addArrangedSubview(time)
            block.addArrangedSubview(delta)
            box.addArrangedSubview(block)
            self.clockEntries.append((name, time, delta))
        }
        if self.sidebarMode {
            box.addArrangedSubview(NSView())
        }
    }

    @objc private func openQuotaPopup() {
        guard let window = self.window else { return }
        let rect = window.convertToScreen(self.convert(self.bounds, to: nil))
        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
            "module": "Quota",
            "origin": rect.origin,
            "center": rect.width / 2
        ])
    }

    static func quotaColor(_ pct: Double) -> NSColor {
        if pct > 50 { return Design.good }
        if pct >= 20 { return Design.warn }
        return Design.critical
    }
}

// Standalone world-clocks card for the dashboard layout. Sits beside the
// PowerFlow hero (Row 1, ~38% width) and mirrors InfoStrip's sidebar-mode
// clock rendering: header + one row per timezone, with the local entry
// emphasized. The dashboard's InfoStrip only renders the Quota section, so
// this card is the single place clocks appear in dashboard mode.
private class ClockCard: NSStackView {
    // matches the PowerFlow hero card height so row 1 reads as two equal cards
    static let heroHeight: CGFloat = 118

    private var portal: CombinedClockPortal?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var localEntry: (name: NSTextField, time: NSTextField)? = nil
    private var cityEntries: [(name: NSTextField, time: NSTextField, delta: NSTextField)] = []
    private var clockNames: [String] = []
    private let box = NSStackView()

    init() {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.orientation = .vertical
        self.alignment = .width
        self.distribution = .fill
        self.spacing = 0
        self.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        self.box.orientation = .vertical
        self.box.alignment = .width
        self.box.distribution = .fill
        self.box.spacing = 6
        self.box.edgeInsets = NSEdgeInsets(top: 10, left: 13, bottom: 10, right: 13)
        self.box.wantsLayer = true
        self.box.applyCardStyle()
        self.addArrangedSubview(self.box)
        self.box.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true

        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: ClockCard.heroHeight)
        self.heightConstraint?.isActive = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(self.openClockPopup))
        self.box.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.box.applyCardStyle()
    }

    func bind(_ portal: CombinedClockPortal?) {
        self.portal = portal
    }

    func setWidth(_ width: CGFloat) {
        if self.widthConstraint == nil {
            self.widthConstraint = self.widthAnchor.constraint(equalToConstant: width)
            self.widthConstraint?.isActive = true
        } else {
            self.widthConstraint?.constant = width
        }
    }

    func refresh() {
        guard let portal = self.portal else {
            self.box.isHidden = true
            return
        }
        let readings = portal.clockReadings
        guard !readings.isEmpty else {
            self.box.isHidden = true
            return
        }
        self.box.isHidden = false
        if readings.map({ $0.name }) != self.clockNames {
            self.rebuild(readings)
        }
        var cityIdx = 0
        for r in readings {
            if r.isLocal {
                self.localEntry?.time.stringValue = r.time
            } else if cityIdx < self.cityEntries.count {
                self.cityEntries[cityIdx].time.stringValue = r.time
                self.cityEntries[cityIdx].delta.stringValue = r.dayDelta == 0 ? "" : String(format: "%+dd", r.dayDelta)
                cityIdx += 1
            }
        }
    }

    // Layout: header row, then a two-column body sized to the 118pt hero
    // height — the local city as the left hero (name + 26pt time), other
    // cities stacked on the right. The previous single-column list needed
    // ~140pt for five cities and was crushed into 0pt-high rows inside the
    // old 62pt frame, printing five city names on top of each other.
    private func rebuild(_ readings: [ClockReading]) {
        self.box.subviews.forEach { $0.removeFromSuperview() }
        self.localEntry = nil
        self.cityEntries = []

        let locals = readings.filter { $0.isLocal }
        // cap the right column at 4 rows so the body always fits the fixed
        // hero height (4 × 15pt rows + 3 × 3pt gaps = 69pt)
        let cities = Array(readings.filter { !$0.isLocal }.prefix(4))
        self.clockNames = readings.map { $0.name }

        let title = NSStackView()
        title.orientation = .horizontal
        title.alignment = .centerY
        title.spacing = 5
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        icon.contentTintColor = .systemBlue
        let label = NSTextField(labelWithString: localizedString("World Clocks"))
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Design.secondaryTextColor
        title.addArrangedSubview(icon)
        title.addArrangedSubview(label)
        title.addArrangedSubview(NSView())
        self.box.addArrangedSubview(title)

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 16
        content.distribution = .fill

        let leftCol = NSStackView()
        leftCol.orientation = .vertical
        leftCol.alignment = .leading
        leftCol.spacing = 3
        if let local = locals.first {
            let nameRow = NSStackView()
            nameRow.orientation = .horizontal
            nameRow.spacing = 5
            let name = NSTextField(labelWithString: local.name)
            name.font = .systemFont(ofSize: 11.5, weight: .semibold)
            name.textColor = .systemBlue
            nameRow.addArrangedSubview(name)
            let localTag = NSTextField(labelWithString: localizedString("World Clock Local"))
            localTag.font = .systemFont(ofSize: 8.5, weight: .medium)
            localTag.textColor = .systemBlue
            nameRow.addArrangedSubview(localTag)
            let time = NSTextField(labelWithString: local.time)
            time.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
            time.textColor = .systemBlue
            leftCol.addArrangedSubview(nameRow)
            leftCol.addArrangedSubview(time)
            self.localEntry = (name, time)
        }

        let rightCol = NSStackView()
        rightCol.orientation = .vertical
        rightCol.alignment = .width
        rightCol.spacing = 3
        for r in cities {
            let block = NSStackView()
            block.orientation = .horizontal
            block.alignment = .centerY
            block.spacing = 5

            let name = NSTextField(labelWithString: r.name)
            name.font = .systemFont(ofSize: 11, weight: .regular)
            name.textColor = Design.secondaryTextColor
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let time = NSTextField(labelWithString: r.time)
            time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            time.textColor = .labelColor

            let delta = NSTextField(labelWithString: "")
            delta.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
            delta.textColor = Design.secondaryTextColor
            delta.alignment = .right
            delta.widthAnchor.constraint(equalToConstant: 26).isActive = true

            block.addArrangedSubview(name)
            block.addArrangedSubview(NSView())
            block.addArrangedSubview(time)
            block.addArrangedSubview(delta)
            rightCol.addArrangedSubview(block)
            self.cityEntries.append((name, time, delta))
        }

        content.addArrangedSubview(leftCol)
        content.addArrangedSubview(rightCol)
        rightCol.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.52, constant: -16).isActive = true

        self.box.addArrangedSubview(content)
        // leftover hero height pools after the body instead of stretching a row
        self.box.addArrangedSubview(NSView())
    }

    public override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }

    @objc private func openClockPopup() {
        guard let window = self.window else { return }
        let rect = window.convertToScreen(self.convert(self.bounds, to: nil))
        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
            "module": "Clock",
            "origin": rect.origin,
            "center": rect.width / 2
        ])
    }
}

// One row per provider in the quota strip. Windows map to fixed columns
// (5h / week / monthly) so bars align vertically across rows; the row shows
// only the window slots that carry data (except the anchor slot, which holds
// the row visible to carry an error).
public enum QuotaProvider: CaseIterable {
    case kimi
    case kimi2
    case codex
    case openCode

    var label: String {
        switch self {
        case .kimi: return localizedString("Quota provider Kimi 1")
        case .kimi2: return localizedString("Quota provider Kimi 2")
        case .codex: return localizedString("Quota provider Codex")
        case .openCode: return localizedString("Quota provider OpenCode")
        }
    }
}

// Layout metrics for the provider-row redesign. The compact strip height is
// derived from the visible row count so a new provider can never re-introduce
// the clipping regression (7 fixed cells in a fixed 46px card).
private enum QuotaRowMetrics {
    static let rowHeight: CGFloat = 22      // 6pt bar + 2pt gap + ~12pt text line
    static let rowSpacing: CGFloat = 5
    static let headerHeight: CGFloat = 14
    static let insets: CGFloat = 9 * 2      // strip edge insets (top+bottom)

    static func stripHeight(visibleRows: Int) -> CGFloat {
        let content = CGFloat(max(visibleRows, 1)) * rowHeight
            + CGFloat(max(visibleRows, 1) - 1) * rowSpacing
            + headerHeight
        return content + insets
    }
}

// MARK: - grouped quota list (dashboard sidebar)

// One line per REAL window: "5小时  ▓▓▓▓░  100%  4时17分".
// A provider that does not report a window (Kimi/Codex expose no monthly
// quota) simply gets no line — the previous fixed 3-column grid drew an empty
// gray track for them, which read as "0%" and padded the card with nothing.
private class QuotaWindowRow: NSStackView {
    private let bar = QuotaMiniBar()
    private let valueField = NSTextField(labelWithString: "—")
    private let countdownField = NSTextField(labelWithString: "")

    init(windowTitle: String) {
        super.init(frame: .zero)

        self.orientation = .horizontal
        // must be .fill: NSStackView defaults to .gravityAreas, which packs
        // the fixed-width children into a gravity cluster and leaves the bar
        // collapsed (title measured -4pt wide, value at x = -24)
        self.distribution = .fill
        self.alignment = .centerY
        self.spacing = 8

        let title = NSTextField(labelWithString: windowTitle)
        title.font = Design.labelFont
        title.textColor = Design.secondaryTextColor
        title.lineBreakMode = .byTruncatingTail
        title.widthAnchor.constraint(equalToConstant: 34).isActive = true

        self.bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        self.bar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        self.valueField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        self.valueField.alignment = .right
        self.valueField.widthAnchor.constraint(equalToConstant: 38).isActive = true

        self.countdownField.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        self.countdownField.textColor = Design.mutedTextColor
        self.countdownField.alignment = .right
        self.countdownField.lineBreakMode = .byTruncatingTail
        self.countdownField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        self.addArrangedSubview(title)
        self.addArrangedSubview(self.bar)
        self.addArrangedSubview(self.valueField)
        self.addArrangedSubview(self.countdownField)
        // 20pt per line. In the 2x2 dashboard grid the block height is fixed
        // (101pt) and the rows spread via equal spacers, so the old "18pt ×
        // 7 lines fits the card" arithmetic no longer applies — 20pt rows are
        // safe and match the approved mockup.
        self.heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(pct: Double?, resetAt: Date?, note: String?) {
        guard let p = pct else {
            self.isHidden = true
            self.valueField.stringValue = ""
            self.countdownField.stringValue = ""
            return
        }
        self.isHidden = false
        let color = InfoStrip.quotaColor(p)
        self.bar.set(fraction: p / 100, color: color)
        self.valueField.stringValue = "\(Int(p.rounded()))%"
        self.valueField.textColor = color
        self.valueField.toolTip = note ?? localizedString("Quota remaining", "\(Int(p.rounded()))")
        if let deadline = resetAt, let text = QuotaCountdownFormatter.text(until: deadline) {
            self.countdownField.stringValue = text
            self.countdownField.toolTip = localizedString("Quota updated at", shortDateText(deadline))
        } else {
            self.countdownField.stringValue = ""
            self.countdownField.toolTip = nil
        }
    }

    /// Fallback line when a provider returns nothing at all.
    func setError(_ message: String?) {
        self.isHidden = false
        self.bar.set(fraction: 0, color: .systemRed)
        self.valueField.stringValue = "!"
        self.valueField.textColor = .systemRed
        self.valueField.toolTip = message
        self.countdownField.stringValue = ""
        self.countdownField.toolTip = nil
    }
}

// A provider block: its name, then one line per window it actually reports.
private class QuotaGroupView: NSStackView {
    let rows: [QuotaWindowRow]

    init(providerLabel: String, windowTitles: [String]) {
        self.rows = windowTitles.map { QuotaWindowRow(windowTitle: $0) }
        super.init(frame: .zero)

        self.orientation = .vertical
        self.alignment = .width
        // Rows spread evenly across the block height (space-evenly): flexible
        // spacers, all equal height, above the first row and after every row.
        // The title hugs at .required so surplus height lands in the spacers
        // instead of inflating the 14pt title line (the old gravity-area
        // stack failed the opposite way — compression squeezed it to 5pt).
        self.distribution = .fill
        self.spacing = 0

        let title = NSTextField(labelWithString: providerLabel)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .left
        self.addArrangedSubview(title)
        // the default autoresizing mask pins the label to its intrinsic width
        // and parks it at the trailing edge; opt out and pin it to the card.
        // Must run AFTER the label joins the hierarchy — a constraint between
        // two views with no common ancestor throws on activation.
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
        // the provider name is the row's only label — never let it shrink
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        title.setContentHuggingPriority(.required, for: .vertical)

        func makeSpacer() -> NSView {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            return spacer
        }
        var spacers: [NSView] = []
        let topSpacer = makeSpacer()
        spacers.append(topSpacer)
        self.addArrangedSubview(topSpacer)
        self.rows.forEach { row in
            self.addArrangedSubview(row)
            // pin every row to the group width so the bar can stretch
            row.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
            let spacer = makeSpacer()
            spacers.append(spacer)
            self.addArrangedSubview(spacer)
        }
        for spacer in spacers.dropFirst() {
            spacer.heightAnchor.constraint(equalTo: spacers[0].heightAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// windows and notes are parallel to self.rows; a nil pct hides the row.
    func set(windows: [(pct: Double?, resetAt: Date?)], note: String?, error: String?) {
        guard windows.count == self.rows.count else { return }
        let hasValue = windows.contains { $0.pct != nil }
        self.isHidden = !hasValue && (error?.isEmpty ?? true)
        guard !self.isHidden else { return }
        for (i, w) in windows.enumerated() {
            self.rows[i].set(pct: w.pct, resetAt: w.resetAt, note: note)
        }
        if !hasValue {
            self.rows[0].setError(error)
        }
    }
}

private class QuotaProviderRow: NSStackView {
    static let labelWidth: CGFloat = 42
    private let provider: QuotaProvider
    private let labelField: NSTextField
    // One slot per window column; slot 0..2 = 5h / weekly / monthly.
    // Vertical slot layout: bar on its own line, value+countdown beneath.
    // A horizontal bar+number+countdown row needs ~120pt per window; inside a
    // 316pt sidebar card three of them squeezed the bars into dots. Stacking
    // gives every bar a real width at any card width.
    private var slots: [(bar: QuotaMiniBar, value: NSTextField, reset: NSTextField, valueStack: NSStackView)] = []

    init(provider: QuotaProvider) {
        self.provider = provider
        self.labelField = NSTextField(labelWithString: provider.label)
        self.labelField.font = Design.subFont
        self.labelField.textColor = Design.secondaryTextColor
        self.labelField.lineBreakMode = .byTruncatingTail
        self.labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.labelField.setContentHuggingPriority(.required, for: .horizontal)
        self.labelField.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true

        super.init(frame: .zero)
        self.orientation = .horizontal
        // Center the label against the whole slot (bar + text line), not just
        // the bar line — the label otherwise floats above the row's visual
        // center.
        self.alignment = .centerY
        self.spacing = 6
        self.addArrangedSubview(self.labelField)

        var slotViews: [NSView] = []
        for _ in 0..<3 {
            let bar = QuotaMiniBar()
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
            value.alignment = .left
            value.textColor = .labelColor

            let reset = NSTextField(labelWithString: "")
            reset.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            reset.alignment = .right
            reset.textColor = Design.mutedTextColor
            reset.lineBreakMode = .byTruncatingTail
            // must NOT be .required: it would fight the required equal-width
            // slot constraints below and Auto Layout would resolve the conflict
            // arbitrarily — the monthly column ("12天 21时") stretched ~2x
            // wider, throwing the 5h/week/month headers off their columns
            reset.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

            let valueStack = NSStackView(views: [value, NSView(), reset])
            valueStack.orientation = .horizontal
            valueStack.alignment = .firstBaseline
            valueStack.spacing = 3

            // bar fills the slot width; text line hugs under it
            let slot = NSStackView(views: [bar, valueStack])
            slot.orientation = .vertical
            slot.alignment = .width
            slot.spacing = 3

            self.addArrangedSubview(slot)
            self.slots.append((bar, value, reset, valueStack))
            slotViews.append(slot)
        }
        // The three window slots share one equal width regardless of how many
        // are visible — hiding a slot's content must not shrink its column,
        // otherwise the 5h/周/月 columns stop lining up across rows.
        for i in 1..<slotViews.count {
            slotViews[i].widthAnchor.constraint(equalTo: slotViews[0].widthAnchor).isActive = true
            slotViews[i].setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        slotViews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.configure(sidebar: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(sidebar: Bool) {
        self.spacing = sidebar ? 8 : 6
    }

    /// data: one entry per window slot (exactly 3; trailing windows may be nil).
    /// errorSlot: which slot shows the row error when no window has data.
    func set(windows: [(pct: Double?, resetAt: Date?)], error: String?, errorSlot: Int, note: String?) {
        guard windows.count == self.slots.count else { return }
        let hasAny = windows.contains { $0.pct != nil }

        for (idx, slot) in self.slots.enumerated() {
            let entry = windows[idx]
            if let p = entry.pct {
                slot.bar.isHidden = false
                slot.valueStack.isHidden = false
                slot.bar.set(fraction: p / 100, color: InfoStrip.quotaColor(p))
                slot.value.stringValue = "\(Int(p.rounded()))%"
                slot.value.textColor = InfoStrip.quotaColor(p)
                slot.value.toolTip = note ?? localizedString("Quota remaining", "\(Int(p.rounded()))")
            } else if hasAny {
                // Window the provider does not offer (e.g. Kimi has no monthly):
                // keep an empty gray TRACK so the 3-column grid stays complete
                // across rows, but hide the text line — no fake numbers.
                slot.bar.isHidden = false
                slot.bar.set(fraction: 0, color: .lightGray)
                slot.valueStack.isHidden = true
                slot.value.stringValue = ""
                slot.value.toolTip = nil
            } else if idx == errorSlot, let e = error, !e.isEmpty {
                slot.bar.isHidden = false
                slot.bar.set(fraction: 0, color: .systemRed)
                slot.valueStack.isHidden = false
                slot.value.stringValue = "!"
                slot.value.textColor = .systemRed
                slot.value.toolTip = e
            } else {
                slot.bar.isHidden = false
                slot.bar.set(fraction: 0, color: .lightGray)
                slot.valueStack.isHidden = true
                slot.value.stringValue = ""
                slot.value.toolTip = nil
            }
            if let deadline = entry.resetAt, entry.pct != nil,
               let text = QuotaCountdownFormatter.text(until: deadline) {
                slot.reset.isHidden = false
                slot.reset.stringValue = text
                slot.reset.toolTip = localizedString("Quota updated at", shortDateText(deadline))
            } else {
                slot.reset.isHidden = true
                slot.reset.stringValue = ""
            }
        }
    }
}

private func shortDateText(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "MM-dd HH:mm"
    return fmt.string(from: date)
}

private class QuotaCell: NSStackView {
    private let bar = QuotaMiniBar()
    private let titleField: NSTextField
    private let valueField: NSTextField
    private let resetField: NSTextField
    private var titleWidthConstraint: NSLayoutConstraint?
    private var valueWidthConstraint: NSLayoutConstraint?
    private var resetWidthConstraint: NSLayoutConstraint?

    init(title: String) {
        self.titleField = NSTextField(labelWithString: title)
        self.titleField.font = Design.subFont
        self.titleField.textColor = Design.secondaryTextColor
        self.titleField.lineBreakMode = .byTruncatingTail

        self.valueField = NSTextField(labelWithString: "—")
        self.valueField.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        self.valueField.alignment = .right
        self.valueField.textColor = .labelColor

        self.resetField = NSTextField(labelWithString: "")
        self.resetField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        self.resetField.alignment = .right
        self.resetField.textColor = Design.mutedTextColor
        self.resetField.isHidden = true
        self.resetField.lineBreakMode = .byTruncatingTail
        self.resetField.setContentCompressionResistancePriority(.required, for: .horizontal)

        super.init(frame: .zero)

        self.bar.heightAnchor.constraint(equalToConstant: 7).isActive = true
        self.bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.configure(sidebar: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not implemented")
    }

    func configure(sidebar: Bool) {
        self.titleWidthConstraint?.isActive = false
        self.valueWidthConstraint?.isActive = false
        self.resetWidthConstraint?.isActive = false
        self.titleWidthConstraint = nil
        self.valueWidthConstraint = nil
        self.resetWidthConstraint = nil
        self.arrangedSubviews.forEach {
            self.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        self.distribution = .fill
        if sidebar {
            // Full-width comparison rows: all three plans share the same bar
            // scale, so 21% visibly occupies one fifth of the available track.
            self.orientation = .horizontal
            self.alignment = .centerY
            self.spacing = 8
            self.titleWidthConstraint = self.titleField.widthAnchor.constraint(equalToConstant: 54)
            self.valueWidthConstraint = self.valueField.widthAnchor.constraint(equalToConstant: 38)
            self.resetWidthConstraint = self.resetField.widthAnchor.constraint(equalToConstant: 58)
            self.titleWidthConstraint?.isActive = true
            self.valueWidthConstraint?.isActive = true
            self.resetWidthConstraint?.isActive = true
            self.addArrangedSubview(self.titleField)
            self.addArrangedSubview(self.bar)
            self.addArrangedSubview(self.valueField)
            self.addArrangedSubview(self.resetField)
        } else {
            // Compact mode keeps three equal mini gauges. Text owns the first
            // line and the complete track gets the second line.
            self.orientation = .vertical
            self.alignment = .width
            self.spacing = 3
            let header = NSStackView()
            header.orientation = .horizontal
            header.alignment = .firstBaseline
            header.distribution = .fill
            header.spacing = 4
            header.addArrangedSubview(self.titleField)
            header.addArrangedSubview(NSView())
            header.addArrangedSubview(self.valueField)
            self.addArrangedSubview(header)
            self.addArrangedSubview(self.bar)
            self.addArrangedSubview(self.resetField)
        }
    }

    func set(remainingPct: Double?, color: NSColor, stale: Bool = false, note: String? = nil) {
        if let p = remainingPct {
            // A stale value keeps its position and traffic-light hue but is faded,
            // so "the refresh failed" reads differently from "the quota is fine".
            let shade = stale ? color.withAlphaComponent(0.4) : color
            self.bar.set(fraction: p / 100, color: shade)
            self.valueField.stringValue = "\(Int(p.rounded()))%"
            self.valueField.textColor = shade
            self.toolTip = note ?? localizedString("Quota remaining", "\(Int(p.rounded()))")
        } else {
            self.bar.set(fraction: 0, color: .lightGray)
            self.valueField.stringValue = "—"
            self.valueField.textColor = Design.mutedTextColor
            self.toolTip = nil
        }
    }

    func setError(_ message: String) {
        self.bar.set(fraction: 0, color: .systemRed)
        self.valueField.stringValue = "!"
        self.valueField.textColor = .systemRed
        self.toolTip = message
    }

    /// Called by InfoStrip's one-second refresh timer. This recomputes display
    /// text locally; it never causes an additional quota API request.
    func set(countdownUntil deadline: Date?) {
        guard let text = QuotaCountdownFormatter.text(until: deadline) else {
            self.resetField.isHidden = true
            self.resetField.stringValue = ""
            return
        }
        self.resetField.isHidden = false
        self.resetField.stringValue = text
    }
}

private class QuotaMiniBar: NSView {
    private var fraction: Double = 0
    private var color: NSColor = .lightGray

    func set(fraction: Double, color: NSColor) {
        self.fraction = max(0, min(fraction, 1))
        self.color = color
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard self.bounds.height > 0 else { return }
        let radius = self.bounds.height / 2
        let track = NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius)
        Design.track.setFill()
        track.fill()

        guard self.fraction > 0 else { return }

        // A tiny fraction (5% of a ~90pt track = 4.5pt) is smaller than the
        // corner radius and visually collapses into a dot that reads as
        // "not loaded". Enforce a minimum visible fill of one full cap so
        // any non-zero value stays legible as a bar.
        let minFill = self.bounds.height
        let w = max(self.bounds.width * CGFloat(self.fraction), minFill)
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: self.bounds.height), xRadius: radius, yRadius: radius)

        let lighter = self.color.highlight(withLevel: 0.25) ?? self.color
        let grad = NSGradient(starting: lighter, ending: self.color)

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = self.color.withAlphaComponent(0.35)
        glow.shadowBlurRadius = 3
        glow.shadowOffset = .zero
        glow.set()
        grad?.draw(in: fill, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }
}
