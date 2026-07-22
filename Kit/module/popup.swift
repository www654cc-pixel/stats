//
//  popup.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 11/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public final class PopupCache<T> {
    public var value: T?
    public var initialized: Bool = false
    
    public init() {}
    
    public func apply(_ value: T, visible: Bool, render: (T) -> Void) {
        self.value = value
        if visible || !self.initialized {
            render(value)
            self.initialized = true
        }
    }
    
    public func replay(render: (T) -> Void) {
        if let v = self.value { render(v) }
    }
}

public protocol Popup_p: NSView {
    var keyboardShortcut: [UInt16] { get }
    var sizeCallback: ((NSSize) -> Void)? { get set }
    
    func settings() -> NSView?
    
    func appear()
    func disappear()
    func setKeyboardShortcut(_ binding: [UInt16])
}

open class PopupWrapper: NSStackView, Popup_p {
    public var title: String
    public var keyboardShortcut: [UInt16] = []
    open var sizeCallback: ((NSSize) -> Void)? = nil
    
    public init(_ typ: ModuleType, frame: NSRect) {
        self.title = typ.stringValue
        self.keyboardShortcut = Store.shared.array(key: "\(typ.stringValue)_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []
        
        super.init(frame: frame)
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    open func settings() -> NSView? { return nil }
    open func appear() {}
    open func disappear() {}
    
    open func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "\(self.title)_popup_keyboardShortcut", value: binding)
    }
    
    public func apply<T>(_ value: T, to cache: PopupCache<T>, render: @escaping (T) -> Void) {
        DispatchQueue.main.async {
            cache.apply(value, visible: self.window?.isVisible ?? false, render: render)
        }
    }
    
    public func replay<T>(_ cache: PopupCache<T>, render: (T) -> Void) {
        cache.replay(render: render)
    }
}

public class PopupWindow: NSWindow, NSWindowDelegate {
    private let viewController: PopupViewController
    internal var locked: Bool = false
    internal var openedBy: widget_t? = nil
    
    public init(title: String, module: ModuleType, view: Popup_p?, visibilityCallback: @escaping (_ state: Bool) -> Void) {
        self.viewController = PopupViewController(module: module)
        self.viewController.setup(title: title, view: view)
        
        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: self.viewController.view.frame.width,
                height: self.viewController.view.frame.height
            ),
            // A titled NSWindow installs an NSThemeFrame which still paints a
            // faint full-window sheet even when contentView is transparent.
            // The combined dashboard must be truly frameless so only its
            // individual glass controls participate in composition.
            styleMask: module == .combined ? [.borderless] : [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        
        self.viewController.visibilityCallback = { [weak self] state in
            self?.locked = false
            visibilityCallback(state)
        }
        
        self.title = title
        self.titleVisibility = .hidden
        self.contentViewController = self.viewController
        self.titlebarAppearsTransparent = true
        self.animationBehavior = .default
        self.collectionBehavior = .moveToActiveSpace
        self.backgroundColor = .clear
        self.isOpaque = module != .combined
        // The combined dashboard is a field of independent glass controls,
        // not one large glass card containing smaller cards.
        self.hasShadow = module != .combined
        self.setIsVisible(false)
        self.delegate = self

        if let cv = self.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = module == .combined ? 0 : 18
            cv.layer?.masksToBounds = module != .combined
        }
    }
    
    public func windowWillMove(_ notification: Notification) {
        self.viewController.setCloseButton(true)
        self.locked = true
    }
    
    public func windowDidResignKey(_ notification: Notification) {
        if self.locked {
            return
        }
        
        self.viewController.setCloseButton(false)
        self.setIsVisible(false)
    }
}

internal class PopupViewController: NSViewController {
    fileprivate var visibilityCallback: (_ state: Bool) -> Void = {_ in }
    private var popup: PopupView
    
    public init(module: ModuleType) {
        self.popup = PopupView(frame: NSRect(
            x: 0,
            y: 0,
            width: Constants.Popup.width + (Constants.Popup.margins * 2),
            height: Constants.Popup.height+Constants.Popup.headerHeight
        ), module: module)
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        self.view = self.popup
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        
        self.popup.appear()
        self.visibilityCallback(true)
        NotificationCenter.default.post(name: .popupVisibilityChanged, object: nil, userInfo: ["state": true])
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        
        self.popup.disappear()
        self.visibilityCallback(false)
        NotificationCenter.default.post(name: .popupVisibilityChanged, object: nil, userInfo: ["state": false])
    }
    
    fileprivate func setup(title: String, view: Popup_p?) {
        self.title = title
        self.popup.setTitle(title)
        self.popup.setView(view)
    }
    
    fileprivate func setCloseButton(_ state: Bool) {
        self.popup.setCloseButton(state)
    }
}

internal class PopupView: NSView {
    private var view: Popup_p? = nil
    
    private var foreground: NSView
    private var background: NSView
    
    private let header: HeaderView
    private let body: NSScrollView
    private let chromeHeight: CGFloat
    
    override var intrinsicContentSize: CGSize {
        return CGSize(width: self.frame.width, height: self.frame.height)
    }
    private var windowHeight: CGFloat?
    private var containerHeight: CGFloat?
    
    init(frame: NSRect, module: ModuleType) {
        self.chromeHeight = module == .combined ? 0 : Constants.Popup.headerHeight
        self.header = HeaderView(frame: NSRect(
            x: 0,
            y: frame.height - self.chromeHeight,
            width: frame.width,
            height: self.chromeHeight
        ), module: module)
        self.body = NSScrollView(frame: NSRect(
            x: Constants.Popup.margins,
            y: Constants.Popup.margins,
            width: frame.width - Constants.Popup.margins*2,
            height: frame.height - self.header.frame.height - Constants.Popup.margins*2
        ))
        self.windowHeight = NSScreen.main?.visibleFrame.height
        self.containerHeight = self.body.documentView?.frame.height
        
        self.background = NSView(frame: frame)
        self.background.wantsLayer = true

        // macOS 26+ supplies the real system glass renderer. It handles the
        // refraction, edge lighting and appearance changes that a hand-built
        // blur/gradient stack cannot reproduce. Older systems retain the
        // upstream visual-effect fallback.
        if module == .combined {
            // The dashboard is a constellation of independent glass controls.
            // Keep the window canvas fully transparent so it never reads as a
            // large glass sheet containing smaller glass sheets.
            self.foreground = self.background
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = 18
            glass.tintColor = NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return dark
                    ? NSColor(calibratedWhite: 0.08, alpha: 0.12)
                    : NSColor(calibratedWhite: 1.0, alpha: 0.08)
            }
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = false
            }
            glass.contentView = self.background
            self.foreground = glass
        } else {
            let material = NSVisualEffectView(frame: frame)
            material.material = .menu
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 18
            material.layer?.masksToBounds = true
            material.addSubview(self.background)
            self.foreground = material
        }
        
        super.init(frame: frame)

        self.header.isHidden = module == .combined
        
        self.body.drawsBackground = false
        self.body.backgroundColor = .clear
        // NSScrollView owns an NSClipView which has its own opaque default
        // background. Clearing only the scroll view leaves a pale rectangle
        // visible through the gaps between independent glass cards.
        self.body.contentView.drawsBackground = false
        self.body.contentView.backgroundColor = .clear
        self.body.contentView.wantsLayer = true
        self.body.contentView.layer?.backgroundColor = NSColor.clear.cgColor
        self.body.translatesAutoresizingMaskIntoConstraints = true
        self.body.borderType = .noBorder
        self.body.hasVerticalScroller = true
        self.body.hasHorizontalScroller = false
        self.body.autohidesScrollers = true
        self.body.horizontalScrollElasticity = .none
        
        self.addSubview(self.foreground, positioned: .below, relativeTo: .none)
        self.addSubview(self.header)
        self.addSubview(self.body)

    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.background.layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    fileprivate func setView(_ view: Popup_p?) {
        self.view = view
        
        var isScrollVisible: Bool = false
        var size: NSSize = NSSize(
            width: (view?.frame.width ?? Constants.Popup.width) + (Constants.Popup.margins*2),
            height: (view?.frame.height ?? 0) + self.chromeHeight + (Constants.Popup.margins*2)
        )
        
        self.windowHeight = NSScreen.main?.visibleFrame.height // for height recalculate when appear/disappear
        self.containerHeight = self.body.documentView?.frame.height // for scroll diff calculation
        if let screenHeight = NSScreen.main?.visibleFrame.height, size.height > screenHeight {
            size.height = screenHeight - Constants.Widget.height
            isScrollVisible = true
        }
        if let screenWidth = NSScreen.main?.visibleFrame.width, size.width > screenWidth {
            size.width = screenWidth
        }
        
        self.setFrameSize(size)
        self.foreground.setFrameSize(size)
        self.background.setFrameSize(size)
        self.body.setFrameSize(NSSize(
            width: size.width - (Constants.Popup.margins*2) + (isScrollVisible ? 20 : 0),
            height: size.height - self.chromeHeight - (Constants.Popup.margins*2)
        ))
        self.header.setFrameOrigin(NSPoint(x: 0, y: size.height - self.chromeHeight))
        
        if let view = view {
            if self.foreground === self.background {
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
            self.body.documentView = view
            view.sizeCallback = { [weak self] size in
                self?.recalculateHeight(size)
            }
        }
    }
    
    fileprivate func setTitle(_ newTitle: String) {
        self.header.setTitle(newTitle)
    }
    
    fileprivate func setCloseButton(_ state: Bool) {
        self.header.setCloseButton(state)
    }
    
    internal func appear() {
        self.view?.appear()
        
        self.display()
        self.body.subviews.first?.display()
        
        if let screenHeight = NSScreen.main?.visibleFrame.height, let size = self.body.documentView?.frame.size {
            if screenHeight != self.windowHeight {
                self.recalculateHeight(size)
            }
        }
        
        if let documentView = self.body.documentView {
            documentView.scroll(NSPoint(x: 0, y: documentView.bounds.size.height))
        }
    }
    internal func disappear() {
        self.header.setCloseButton(false)
        self.view?.disappear()
    }
    
    private func recalculateHeight(_ size: NSSize) {
        var isScrollVisible: Bool = false
        var windowSize: NSSize = NSSize(
            width: size.width + (Constants.Popup.margins*2),
            height: size.height + self.chromeHeight + (Constants.Popup.margins*2)
        )
        let h0 = self.containerHeight ?? 0
        
        self.windowHeight = NSScreen.main?.visibleFrame.height // for height recalculate when appear/disappear
        self.containerHeight = self.body.documentView?.frame.height // for scroll diff calculation
        if let screenHeight = NSScreen.main?.visibleFrame.height, windowSize.height > screenHeight {
            windowSize.height = screenHeight - Constants.Widget.height
            isScrollVisible = true
        }
        if let screenWidth = NSScreen.main?.visibleFrame.width, windowSize.width > screenWidth {
            windowSize.width = screenWidth
        }
        
        self.window?.setContentSize(windowSize)
        self.foreground.setFrameSize(windowSize)
        self.background.setFrameSize(windowSize)
        self.body.setFrameSize(NSSize(
            width: windowSize.width - (Constants.Popup.margins*2) + (isScrollVisible ? 20 : 0),
            height: windowSize.height - self.chromeHeight - (Constants.Popup.margins*2)
        ))
        self.header.setFrameOrigin(NSPoint(
            x: self.header.frame.origin.x,
            y: self.body.frame.height + (Constants.Popup.margins*2)
        ))
        
        if let documentView = self.body.documentView {
            let diff = h0 - (self.body.documentView?.frame.height ?? 0)
            documentView.scroll(NSPoint(
                x: 0,
                y: self.body.documentVisibleRect.origin.y - (diff < 0 ? diff : 0)
            ))
        }
    }

}

internal class HeaderView: NSStackView {
    private var titleView: NSTextField? = nil
    private var activityButton: NSButton?
    
    private var title: String = ""
    private var isCloseAction: Bool = false
    private let activityMonitor: URL?
    private let calendar: URL?
    private var module: ModuleType
    
    init(frame: NSRect, module: ModuleType) {
        self.module = module
        self.activityMonitor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
        self.calendar = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        
        super.init(frame: CGRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height))
        
        self.orientation = .horizontal
        self.distribution = .gravityAreas
        self.spacing = 0
        
        let activity = NSButtonWithPadding()
        activity.frame = CGRect(x: 0, y: 0, width: 24, height: self.frame.height)
        activity.horizontalPadding = activity.frame.height - 24
        activity.bezelStyle = .regularSquare
        activity.translatesAutoresizingMaskIntoConstraints = false
        activity.imageScaling = .scaleNone
        activity.contentTintColor = .secondaryLabelColor
        activity.isBordered = false
        activity.target = self
        activity.focusRingType = .none
        self.activityButton = activity
        self.setupActionButton()
        
        let title = NSTextField(frame: NSRect(x: 0, y: 0, width: frame.width/2, height: 18))
        title.isEditable = false
        title.isSelectable = false
        title.isBezeled = false
        title.wantsLayer = true
        title.textColor = .textColor
        title.backgroundColor = .clear
        title.canDrawSubviewsIntoLayer = true
        title.alignment = .center
        // macOS popover title style: 13pt semibold reads as native chrome,
        // not a window title bar
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.stringValue = ""
        self.titleView = title
        
        let settings = NSButtonWithPadding()
        settings.frame = CGRect(x: 0, y: 0, width: 24, height: self.frame.height)
        settings.horizontalPadding = activity.frame.height - 24
        settings.bezelStyle = .regularSquare
        settings.translatesAutoresizingMaskIntoConstraints = false
        settings.imageScaling = .scaleNone
        settings.image = iconFromSymbol(name: "command", scale: .large)
        settings.contentTintColor = .secondaryLabelColor
        settings.isBordered = false
        settings.action = #selector(self.openSettings)
        settings.target = self
        settings.toolTip = localizedString("Open module")
        settings.focusRingType = .none
        
        self.addArrangedSubview(activity)
        self.addArrangedSubview(title)
        self.addArrangedSubview(settings)
        
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(
                equalToConstant: self.frame.width - activity.intrinsicContentSize.width - settings.intrinsicContentSize.width
            )
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    fileprivate func setTitle(_ newTitle: String) {
        self.title = newTitle
        self.titleView?.stringValue = localizedString(newTitle)
    }
    
    private func setupActionButton() {
        guard let button = self.activityButton else { return }
        
        if self.isCloseAction {
            button.action = #selector(self.closePopup)
            button.image = iconFromSymbol(name: "xmark.circle.fill", scale: .xlarge)
            button.toolTip = localizedString("Close")
            return
        }
        
        if self.module == .clock {
            button.action = #selector(self.openCalendar)
            button.image = iconFromSymbol(name: "calendar", scale: .large)
            button.toolTip = localizedString("Open Calendar")
            return
        } else if self.module == .remote {
            button.action = #selector(self.openSystemStats)
            button.image = iconFromSymbol(name: "globe", scale: .large)
            button.toolTip = localizedString("Open System Stats")
            return
        }
        
        button.action = #selector(self.openActivityMonitor)
        button.image = iconFromSymbol(name: "chart.bar.fill", scale: .medium)
        button.toolTip = localizedString("Open Activity Monitor")
    }
    
    @objc func openActivityMonitor() {
        guard let app = self.activityMonitor else { return }
        if let tab = self.module.activityMonitorTab {
            UserDefaults(suiteName: "com.apple.ActivityMonitor")?.set(tab, forKey: "SelectedTab")
        }
        NSWorkspace.shared.open([], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    
    @objc func openCalendar() {
        guard let app = self.calendar else { return }
        NSWorkspace.shared.open([], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    
    @objc func openSystemStats() {
        guard let url = URL(string: "https://app.system-stats.com") else { return }
        NSWorkspace.shared.open(url)
    }
    
    @objc func openSettings() {
        NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": self.title])
    }
    
    @objc private func closePopup() {
        self.window?.setIsVisible(false)
        self.setCloseButton(false)
        return
    }
    
    fileprivate func setCloseButton(_ state: Bool) {
        guard state != self.isCloseAction else { return }
        self.isCloseAction = state
        self.setupActionButton()
    }
}
