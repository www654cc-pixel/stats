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
        
        self.popup = PopupWindow(title: localizedString("System Overview"), module: .combined, view: Popup()) { _ in }
        
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
    private let calendar: CalendarPortal = CalendarPortal()
    private let proxy: ProxyPortal = ProxyPortal()
    private let launcher: LauncherPortal = LauncherPortal()
    private let infoStrip: InfoStrip = InfoStrip()
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
        self.calendar.refresh()
        self.infoStrip.refresh()
        self.refreshTimer?.invalidate()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tiles.refresh()
            self?.calendar.refresh()
            self?.infoStrip.refresh()
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
        // dashboard (single icon) mode gets the wide three-column layout,
        // the classic combined popup a narrower two-column one
        let dashboard = Store.shared.bool(key: "CombinedModules_icon", defaultValue: false)
        let columns = dashboard ? 3 : 2
        let columnWidth: CGFloat = dashboard ? 316 : Constants.Popup.width
        let width = CGFloat(columns) * columnWidth + CGFloat(columns - 1) * spacing

        self.spacing = spacing

        // power hero card on top
        self.power.setWidth(width)
        self.power.isHidden = !self.power.available
        self.addArrangedSubview(self.power)

        // metric tile grid — cards float on the glass, no divider needed
        self.tiles.rebuild(width: width)
        if !self.tiles.isEmpty {
            self.tiles.refresh()
            self.addArrangedSubview(self.tiles)
        }

        // stock portals only for modules the unified cards don't cover
        // (e.g. Bluetooth). Quota is rendered as its own compact strip below,
        // so it is excluded from this grid.
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

        // merged info strip: Quota (Kimi/Codex) + world clocks in one card
        if let q = modules.first(where: { $0.name == "Quota" && $0.enabled })?.portal as? CombinedQuotaPortal {
            self.infoStrip.bindQuota(q)
        } else {
            self.infoStrip.unbindQuota()
        }
        self.infoStrip.refresh()

        // The wide dashboard uses an asymmetric 2:1 context row: calendar on
        // the left, quotas + world clocks on the right. This is the key Bento
        // break in the composition; the classic two-column popup keeps the
        // compact linear arrangement for compatibility.
        if dashboard {
            let sidebarWidth = columnWidth
            let calendarWidth = width - sidebarWidth - spacing
            let contextHeight: CGFloat = 252
            self.calendar.setSize(width: calendarWidth, height: contextHeight)
            self.infoStrip.setWidth(sidebarWidth, sidebar: true, height: contextHeight)
            self.calendar.refresh()

            let context = NSGridView(views: [[self.calendar, self.infoStrip]])
            context.columnSpacing = spacing
            context.rowSpacing = 0
            context.column(at: 0).width = calendarWidth
            context.column(at: 1).width = sidebarWidth
            context.column(at: 0).xPlacement = .fill
            context.column(at: 1).xPlacement = .fill
            context.row(at: 0).height = contextHeight
            context.row(at: 0).yPlacement = .fill
            self.addArrangedSubview(context)
        } else {
            self.infoStrip.setWidth(width, sidebar: false, height: InfoStrip.compactHeight)
            self.addArrangedSubview(self.infoStrip)
            self.calendar.setSize(width: width, height: nil)
            self.calendar.refresh()
            self.addArrangedSubview(self.calendar)
        }

        // Compact utilities close the composition as one asymmetric row
        // instead of two full-width tails with large empty regions.
        let proxyWidth = (width - spacing) * 0.62
        let launcherWidth = width - spacing - proxyWidth
        self.proxy.setWidth(proxyWidth)
        self.proxy.isHidden = !self.proxy.reachable
        self.launcher.setWidth(launcherWidth)
        let utilities = NSGridView(views: [[self.proxy, self.launcher]])
        utilities.columnSpacing = spacing
        utilities.rowSpacing = 0
        utilities.column(at: 0).width = proxyWidth
        utilities.column(at: 1).width = launcherWidth
        utilities.column(at: 0).xPlacement = .fill
        utilities.column(at: 1).xPlacement = .fill
        utilities.row(at: 0).yPlacement = .fill
        self.addArrangedSubview(utilities)

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

// MARK: - Info strip (Quota + Clock merged)

// One horizontal card: the left ~46% shows the Quota mini-cells (Kimi 5h /
// Kimi 周 / Codex), the right side shows the world clock row. Merges the
// former two separate cards into a single 46px line, reclaiming ~50px.
private class InfoStrip: NSStackView {
    static let compactHeight: CGFloat = 46

    private var quotaSource: CombinedQuotaPortal?
    private var quotaCells: [QuotaCell] = []
    private var quotaBox: NSStackView?
    private var quotaSection: NSStackView?
    private var quotaHeader: NSView?
    private var quotaWidthConstraint: NSLayoutConstraint?
    private var sectionDivider: NSBox?
    private var heightConstraint: NSLayoutConstraint?
    private var sidebarMode: Bool = false

    private var clockEntries: [(name: NSTextField, time: NSTextField, delta: NSTextField)] = []
    private var clockNames: [String] = []
    private var clockBox: NSStackView?
    private var latestReadings: [ClockReading] = []

    init() {
        super.init(frame: .zero)

        self.wantsLayer = true
        self.applyCardStyle()

        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fill
        self.spacing = 10
        self.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 12)
        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: InfoStrip.compactHeight)
        self.heightConstraint?.isActive = true

        // left: Quota (fixed share)
        let quotaSection = NSStackView()
        quotaSection.orientation = .vertical
        quotaSection.alignment = .width
        quotaSection.spacing = 8
        quotaSection.setContentHuggingPriority(.required, for: .vertical)
        quotaSection.setContentCompressionResistancePriority(.required, for: .vertical)

        let quotaHeader = NSStackView()
        quotaHeader.orientation = .horizontal
        quotaHeader.alignment = .centerY
        quotaHeader.spacing = 5
        let quotaIcon = NSImageView()
        quotaIcon.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
        quotaIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        quotaIcon.contentTintColor = .systemGreen
        let quotaLabel = NSTextField(labelWithString: localizedString("Quota"))
        quotaLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        quotaLabel.textColor = .secondaryLabelColor
        quotaHeader.addArrangedSubview(quotaIcon)
        quotaHeader.addArrangedSubview(quotaLabel)
        quotaHeader.addArrangedSubview(NSView())
        quotaSection.addArrangedSubview(quotaHeader)

        let q = NSStackView()
        q.orientation = .horizontal
        q.alignment = .centerY
        q.distribution = .fillEqually
        q.spacing = 10
        for title in ["Kimi 5h", "Kimi 周", "Codex"] {
            let cell = QuotaCell(title: title)
            self.quotaCells.append(cell)
            q.addArrangedSubview(cell)
        }
        quotaSection.addArrangedSubview(q)
        self.addArrangedSubview(quotaSection)
        self.quotaBox = q
        self.quotaSection = quotaSection
        self.quotaHeader = quotaHeader

        let divider = NSBox()
        divider.boxType = .separator
        divider.isHidden = true
        self.addArrangedSubview(divider)
        self.sectionDivider = divider

        // right: Clock (remaining width)
        let c = NSStackView()
        c.orientation = .horizontal
        c.alignment = .centerY
        c.distribution = .fill
        c.spacing = 9
        self.addArrangedSubview(c)
        self.clockBox = c

        let click = NSClickGestureRecognizer(target: self, action: #selector(self.openQuotaPopup))
        quotaSection.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    // set after the strip is in the popup tree and its width is known; using a
    // constant (not a multiplier on self.widthAnchor) avoids the mutually-
    // exclusive Auto Layout constraint that fires during init
    internal func setWidth(_ width: CGFloat, sidebar: Bool, height: CGFloat) {
        self.sidebarMode = sidebar
        self.orientation = sidebar ? .vertical : .horizontal
        self.alignment = sidebar ? .width : .centerY
        self.spacing = sidebar ? 10 : 10
        self.edgeInsets = sidebar
            ? NSEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)
            : NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 12)
        self.heightConstraint?.constant = height
        self.quotaHeader?.isHidden = !sidebar
        self.sectionDivider?.isHidden = !sidebar

        self.quotaWidthConstraint?.isActive = false
        self.quotaWidthConstraint = nil
        if !sidebar {
            self.quotaWidthConstraint = self.quotaSection?.widthAnchor.constraint(equalToConstant: width * 0.46)
            self.quotaWidthConstraint?.isActive = true
        }
        self.clockBox?.orientation = sidebar ? .vertical : .horizontal
        self.clockBox?.alignment = sidebar ? .width : .centerY
        self.clockBox?.distribution = .fill
        self.clockBox?.spacing = sidebar ? 8 : 9
        self.rebuildClock(self.latestReadings)
    }

    func bindQuota(_ portal: CombinedQuotaPortal?) {
        self.quotaSource = portal
    }

    func unbindQuota() {
        self.quotaSource = nil
    }

    func refresh() {
        // quota (left)
        if let q = self.quotaSource {
            self.quotaSection?.isHidden = false
            InfoStrip.apply(quota: q, to: self.quotaCells)
        } else {
            self.quotaSection?.isHidden = true
        }

        // clock (right)
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

    private static func apply(quota q: CombinedQuotaPortal, to cells: [QuotaCell]) {
        guard cells.count == 3 else { return }
        if let p = q.kimiFiveHourPct {
            cells[0].set(remainingPct: p, color: InfoStrip.quotaColor(p))
        } else {
            cells[0].set(remainingPct: nil, color: .lightGray)
        }
        if let p = q.kimiWeeklyPct {
            cells[1].set(remainingPct: p, color: InfoStrip.quotaColor(p))
        } else {
            cells[1].set(remainingPct: nil, color: .lightGray)
        }
        if let p = q.codexRemainingPct {
            cells[2].set(remainingPct: p, color: InfoStrip.quotaColor(p))
        } else if let e = q.codexError, !e.isEmpty {
            cells[2].setError(e)
        } else {
            cells[2].set(remainingPct: nil, color: .lightGray)
        }
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
            label.textColor = .secondaryLabelColor
            title.addArrangedSubview(icon)
            title.addArrangedSubview(label)
            title.addArrangedSubview(NSView())
            box.addArrangedSubview(title)
        } else {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            icon.contentTintColor = .tertiaryLabelColor
            box.addArrangedSubview(icon)
        }

        for r in readings {
            let block = NSStackView()
            block.orientation = .horizontal
            block.alignment = .firstBaseline
            block.spacing = 4

            let name = NSTextField(labelWithString: r.name)
            name.font = .systemFont(ofSize: 11, weight: .regular)
            name.textColor = r.isLocal ? .systemBlue : .secondaryLabelColor
            let time = NSTextField(labelWithString: r.time)
            time.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: r.isLocal ? .semibold : .medium)
            time.textColor = .labelColor
            let delta = NSTextField(labelWithString: "")
            delta.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
            delta.textColor = .secondaryLabelColor
            delta.alignment = .right
            delta.widthAnchor.constraint(equalToConstant: 24).isActive = true

            block.addArrangedSubview(name)
            if self.sidebarMode { block.addArrangedSubview(NSView()) }
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

    private static func quotaColor(_ pct: Double) -> NSColor {
        if pct > 50 { return Design.good }
        if pct >= 20 { return Design.warn }
        return Design.critical
    }
}

private class QuotaCell: NSStackView {
    private let bar = QuotaMiniBar()
    private let valueField: NSTextField

    init(title: String) {
        self.valueField = NSTextField(labelWithString: "—")
        self.valueField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        self.valueField.alignment = .right
        self.valueField.textColor = .labelColor

        super.init(frame: .zero)

        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fill
        self.spacing = 5

        let lab = NSTextField(labelWithString: title)
        lab.font = Design.subFont
        lab.textColor = .secondaryLabelColor

        self.bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        self.addArrangedSubview(lab)
        self.addArrangedSubview(self.bar)
        self.addArrangedSubview(self.valueField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not implemented")
    }

    func set(remainingPct: Double?, color: NSColor) {
        if let p = remainingPct {
            self.bar.set(fraction: p / 100, color: color)
            self.valueField.stringValue = "\(Int(p.rounded()))%"
        } else {
            self.bar.set(fraction: 0, color: .lightGray)
            self.valueField.stringValue = "—"
        }
    }

    func setError(_ message: String) {
        self.bar.set(fraction: 0, color: .systemRed)
        self.valueField.stringValue = "!"
        self.toolTip = message
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

        let w = max(self.bounds.width * CGFloat(self.fraction), self.bounds.height)
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
