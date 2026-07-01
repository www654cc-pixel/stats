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

        // single icon mode: one fixed icon, click always opens the overview popup
        if self.singleIcon {
            self.menuBarItem?.button?.image = self.icon()
            self.menuBarItem?.length = 30
            self.menuBarItem?.button?.target = self
            self.menuBarItem?.button?.action = #selector(self.togglePopup)
            self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
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
        if let item = self.menuBarItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.menuBarItem = nil
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
        } else {
            popup.setIsVisible(false)
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

private class Popup: NSStackView, Popup_p {
    fileprivate var keyboardShortcut: [UInt16] = []
    fileprivate var sizeCallback: ((NSSize) -> Void)? = nil

    private let summary: SummaryView = SummaryView()
    private let proxy: ProxyPortal = ProxyPortal()
    private var refreshTimer: Timer?

    init() {
        self.keyboardShortcut = Store.shared.array(key: "CombinedModules_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []

        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = Constants.Popup.spacing

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
        self.summary.refresh()
        self.refreshTimer?.invalidate()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.summary.refresh()
        }
        self.proxy.start()
    }
    fileprivate func disappear() {
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        self.proxy.stop()
    }
    fileprivate func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "CombinedModules_popup_keyboardShortcut", value: binding)
    }

    @objc private func reinit() {
        self.subviews.forEach({ $0.removeFromSuperview() })

        let spacing = Constants.Popup.spacing
        let portals: [Portal_p] = modules.filter({ $0.enabled && $0.portal != nil }).compactMap({ $0.portal })
        let widePortals = portals.filter { $0.isWide }
        let normalPortals = portals.filter { !$0.isWide }

        // dashboard mode lays the portals out in a wide multi-column grid
        let dashboard = Store.shared.bool(key: "CombinedModules_icon", defaultValue: false)
        let columns = (dashboard && normalPortals.count > 1) ? (normalPortals.count > 4 ? 3 : 2) : 1
        let width = CGFloat(columns) * Constants.Popup.width + CGFloat(columns - 1) * spacing

        // overview summary on top, shown when any of the metric-providing modules is enabled
        self.summary.refresh()
        if SummaryView.isAvailable {
            self.summary.setWidth(width)
            self.addArrangedSubview(self.summary)
        }

        if columns == 1 {
            normalPortals.forEach { self.addArrangedSubview($0) }
        } else {
            let grid = NSGridView()
            grid.rowSpacing = spacing
            grid.columnSpacing = spacing

            var row: [NSView] = []
            normalPortals.forEach { p in
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
                grid.column(at: i).width = Constants.Popup.width
                grid.column(at: i).xPlacement = .fill
            }
            for r in 0..<grid.numberOfRows {
                grid.row(at: r).height = Constants.Popup.portalHeight
                grid.row(at: r).yPlacement = .fill
            }
            self.addArrangedSubview(grid)
        }

        // wide portals (e.g. Clock) span the full width below the grid
        widePortals.forEach {
            $0.onResize = { [weak self] in
                guard let self = self else { return }
                self.applySize(width: self.frame.width)
            }
            $0.setWideWidth(width)
            self.addArrangedSubview($0)
        }

        // proxy status section (mihomo), full width below the grid; hides itself when unreachable
        self.proxy.setWidth(width)
        self.proxy.isHidden = !self.proxy.reachable
        self.addArrangedSubview(self.proxy)

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

// MARK: - Overview summary

private class SummaryView: NSStackView {
    static let height: CGFloat = 52

    // the summary is relevant only when at least one metric-providing module is enabled
    static var isAvailable: Bool {
        modules.contains(where: { ["CPU", "RAM", "Sensors"].contains($0.name) && $0.enabled })
    }

    private let powerTile = SummaryTile(title: localizedString("Power"))
    private let cpuTile = SummaryTile(title: localizedString("CPU"))
    private let pressureTile = SummaryTile(title: localizedString("Memory pressure"))
    private let tempTile = SummaryTile(title: localizedString("Temperature"))

    private var widthConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: SummaryView.height))

        self.orientation = .horizontal
        self.distribution = .fillEqually
        self.spacing = Constants.Popup.spacing
        self.heightAnchor.constraint(equalToConstant: SummaryView.height).isActive = true
        self.widthConstraint = self.widthAnchor.constraint(equalToConstant: Constants.Popup.width)
        self.widthConstraint?.isActive = true

        [self.powerTile, self.cpuTile, self.pressureTile, self.tempTile].forEach { self.addArrangedSubview($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setWidth(_ width: CGFloat) {
        self.widthConstraint?.constant = width
        self.setFrameSize(NSSize(width: width, height: SummaryView.height))
    }

    private func thresholdColor(_ value: Double, warn: Double, critical: Double) -> NSColor {
        if value >= critical { return NSColor.systemRed }
        if value >= warn { return NSColor.systemOrange }
        return NSColor.labelColor
    }

    private func portal<T>(_ name: String, as type: T.Type) -> T? {
        guard let m = modules.first(where: { $0.name == name && $0.enabled }) else { return nil }
        return m.portal as? T
    }

    func refresh() {
        // CPU usage
        if let p = self.portal("CPU", as: CombinedCPUPortal.self), let usage = p.lastUsage {
            let percent = Double(Int(usage.rounded(toPlaces: 2) * 100))
            self.cpuTile.set(value: "\(Int(percent))%", color: self.thresholdColor(percent, warn: 60, critical: 85))
            self.cpuTile.isHidden = false
        } else {
            self.cpuTile.isHidden = true
        }

        // Memory pressure
        if let p = self.portal("RAM", as: CombinedRAMPortal.self), let level = p.lastPressure {
            self.pressureTile.set(value: level.rawValue.capitalized, color: level.pressureColor())
            self.pressureTile.isHidden = false
        } else {
            self.pressureTile.isHidden = true
        }

        // Power & max temperature from the Sensors module
        let sensors = self.portal("Sensors", as: CombinedSensorsPortal.self)
        if let power = sensors?.lastPower {
            self.powerTile.set(value: power, color: NSColor.labelColor)
            self.powerTile.isHidden = false
        } else {
            self.powerTile.isHidden = true
        }
        if let temp = sensors?.lastMaxTemp {
            let raw = sensors?.lastMaxTempValue ?? 0
            self.tempTile.set(value: temp, color: self.thresholdColor(raw, warn: 75, critical: 90))
            self.tempTile.isHidden = false
        } else {
            self.tempTile.isHidden = true
        }
    }
}

private class SummaryTile: NSStackView {
    private let valueField: NSTextField

    init(title: String) {
        self.valueField = NSTextField(labelWithString: "–")

        super.init(frame: NSRect.zero)

        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 3

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .centerX
        self.spacing = 2
        self.edgeInsets = NSEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)

        self.valueField.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        self.valueField.alignment = .center
        self.valueField.lineBreakMode = .byTruncatingTail

        let titleField = NSTextField(labelWithString: title)
        titleField.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        titleField.textColor = .secondaryLabelColor
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail

        self.addArrangedSubview(self.valueField)
        self.addArrangedSubview(titleField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func set(value: String, color: NSColor) {
        self.valueField.stringValue = value
        self.valueField.textColor = color
    }
}
