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
        
        self.popup = PopupWindow(title: "Combined modules", module: .combined, view: Popup()) { _ in }
        
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
        self.menuBarItem = NSStatusBar.system.statusItem(withLength: 0)
        DispatchQueue.main.async(execute: {
            self.menuBarItem?.autosaveName = "CombinedModules"
        })
        self.menuBarItem?.button?.toolTip = localizedString("Combined modules")

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
        
        var w: CGFloat = 0
        var i: Int = 0
        self.activeModules.forEach { (m: Module) in
            self.view.addSubview(m.menuBar.view)
            self.view.subviews[i].setFrameOrigin(NSPoint(x: w, y: 0))
            w += m.menuBar.view.frame.width + self.spacing
            i += 1
            
            if self.separator && i < 2 * self.activeModules.count - 1 {
                let separator = NSView(frame: NSRect(x: w, y: 3, width: 1, height: Constants.Widget.height-6))
                separator.wantsLayer = true
                separator.layer?.backgroundColor = (separator.isDarkMode ? NSColor.white : NSColor.black).cgColor
                self.view.addSubview(separator)
                w += 3 + self.spacing
                i += 1
            }
        }
        self.view.setFrameSize(NSSize(width: w, height: self.view.frame.height))
        self.menuBarItem?.length = w
    }
    
    // call when popup appear/disappear
    private func visibilityCallback(_ state: Bool) {}
    
    @objc private func togglePopup(_ sender: NSButton) {
        guard let popup = self.popup, let item = self.menuBarItem, let window = item.button?.window else { return }
        let openedWindows = NSApplication.shared.windows.filter{ $0 is NSPanel }
        openedWindows.forEach{ $0.setIsVisible(false) }
        
        if popup.occlusionState.rawValue == 8192 {
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            popup.contentView?.invalidateIntrinsicContentSize()
            
            let windowCenter = popup.contentView!.intrinsicContentSize.width / 2
            var x = window.frame.origin.x - windowCenter + window.frame.width/2
            let y = window.frame.origin.y - popup.contentView!.intrinsicContentSize.height - 3
            
            let maxWidth = NSScreen.screens.map{ $0.frame.width }.reduce(0, +)
            if x + popup.contentView!.intrinsicContentSize.width > maxWidth {
                x = maxWidth - popup.contentView!.intrinsicContentSize.width - 3
            }
            
            popup.setFrameOrigin(NSPoint(x: x, y: y))
            popup.setIsVisible(true)
            self.popupVisible = true
        } else {
            popup.setIsVisible(false)
            self.popupVisible = false
            // refresh the icon once now that the popup closed, so the menubar
            // catches up immediately instead of waiting up to 3 s
            self.refreshPowerIcon()
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
    private let clockRow: ClockRow = ClockRow()
    private let proxy: ProxyPortal = ProxyPortal()
    private let launcher: LauncherPortal = LauncherPortal()
    private var refreshTimer: Timer?

    init() {
        self.keyboardShortcut = Store.shared.array(key: "CombinedModules_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []

        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = Constants.Popup.spacing

        self.power.onResize = { [weak self] in
            self?.recomputeHeight()
        }
        self.proxy.onResize = { [weak self] in
            guard let self = self else { return }
            self.proxy.isHidden = !self.proxy.reachable
            self.recomputeHeight()
        }
        self.launcher.onResize = { [weak self] in
            guard let self = self else { return }
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
        self.clockRow.refresh()
        self.refreshTimer?.invalidate()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tiles.refresh()
            self?.clockRow.refresh()
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

        let spacing = Constants.Popup.spacing
        // dashboard (single icon) mode gets the wide three-column layout,
        // the classic combined popup a narrower two-column one
        let dashboard = Store.shared.bool(key: "CombinedModules_icon", defaultValue: false)
        let columns = dashboard ? 3 : 2
        let width = CGFloat(columns) * Constants.Popup.width + CGFloat(columns - 1) * spacing

        // power-flow (sankey) hero card on top
        self.power.setWidth(width)
        self.power.isHidden = !self.power.available
        self.addArrangedSubview(self.power)

        // uniform metric tiles for the core modules
        self.tiles.rebuild(width: width)
        if !self.tiles.isEmpty {
            self.tiles.refresh()
            self.addArrangedSubview(self.tiles)
        }

        // stock portals only for modules the unified cards don't cover (e.g. Bluetooth)
        let fallback: [Portal_p] = modules
            .filter({ $0.enabled && $0.portal != nil && !Popup.coveredModules.contains($0.name) })
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

        // single-line world clock row
        self.clockRow.refresh()
        self.addArrangedSubview(self.clockRow)

        // proxy status (mihomo), collapsed to one row; hides itself when unreachable
        self.proxy.setWidth(width)
        self.proxy.isHidden = !self.proxy.reachable
        self.addArrangedSubview(self.proxy)

        // launcher: one row of app icons
        self.launcher.setWidth(width)
        self.addArrangedSubview(self.launcher)

        self.applySize(width: width)
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

// MARK: - Clock row

// single-line world clock: "北京 07:04   莫斯科 07:04   墨西哥城 22:04 −1d"
private class ClockRow: NSStackView {
    static let height: CGFloat = 30

    private var entries: [(name: NSTextField, time: NSTextField, delta: NSTextField)] = []
    private var names: [String] = []

    init() {
        super.init(frame: .zero)

        self.wantsLayer = true
        self.applyCardStyle()

        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fill
        self.spacing = 16
        self.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        self.heightAnchor.constraint(equalToConstant: ClockRow.height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    private func portal() -> CombinedClockPortal? {
        guard let m = modules.first(where: { $0.name == "Clock" && $0.enabled }) else { return nil }
        return m.portal as? CombinedClockPortal
    }

    func refresh() {
        guard let readings = self.portal()?.clockReadings, !readings.isEmpty else {
            self.isHidden = true
            return
        }
        self.isHidden = false

        if readings.map({ $0.name }) != self.names {
            self.rebuild(readings)
        }
        for (i, r) in readings.enumerated() where i < self.entries.count {
            self.entries[i].time.stringValue = r.time
            self.entries[i].delta.stringValue = r.dayDelta == 0 ? "" : String(format: "%+dd", r.dayDelta)
        }
    }

    private func rebuild(_ readings: [ClockReading]) {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.entries = []
        self.names = readings.map { $0.name }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        icon.contentTintColor = .tertiaryLabelColor
        self.addArrangedSubview(icon)

        for r in readings {
            let block = NSStackView()
            block.orientation = .horizontal
            block.spacing = 5

            let name = NSTextField(labelWithString: r.name)
            name.font = .systemFont(ofSize: 10)
            name.textColor = .secondaryLabelColor
            let time = NSTextField(labelWithString: r.time)
            time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            let delta = NSTextField(labelWithString: "")
            delta.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            delta.textColor = .tertiaryLabelColor

            block.addArrangedSubview(name)
            block.addArrangedSubview(time)
            block.addArrangedSubview(delta)
            self.addArrangedSubview(block)
            self.entries.append((name, time, delta))
        }
        self.addArrangedSubview(NSView())
    }
}
