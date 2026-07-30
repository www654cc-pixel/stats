//
//  portal.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 17/02/2023
//  Using Swift 5.0
//  Running on macOS 13.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public protocol Portal_p: NSView {
    var name: String { get }
    // portals that benefit from more horizontal space (e.g. Clock) can opt in.
    // Declared as a protocol requirement (not just an extension default) so
    // overrides dispatch correctly through the `Portal_p` existential type —
    // extension-only members use static dispatch and would always resolve to
    // the default, ignoring conforming types' overrides.
    var isWide: Bool { get }
    // called by the combined overview with the full panel width; wide portals
    // that want a reliable, explicit stretch should override this.
    func setWideWidth(_ width: CGFloat)
    // called by the portal when its intrinsic size changes (e.g. a grid
    // reflows); the combined overview uses this to recompute the popup height.
    var onResize: (() -> Void)? { get set }
}

public extension Portal_p {
    var isWide: Bool { false }
    func setWideWidth(_ width: CGFloat) {}
    var onResize: (() -> Void)? {
        get { nil }
        set { }
    }
}

// Snapshot accessors used by the combined overview (summary + metric tiles).
// Adopted by the module portals so the combined view can read their latest
// values without importing module-private types.
public protocol CombinedCPUPortal: AnyObject {
    var lastUsage: Double? { get }          // 0...1
    var lastSystemLoad: Double? { get }     // 0...1
    var lastUserLoad: Double? { get }       // 0...1
}
public protocol CombinedRAMPortal: AnyObject {
    var lastPressure: RAMPressure? { get }
    var lastUsage: Double? { get }          // 0...1
    var lastUsedBytes: Double? { get }
    var lastTotalBytes: Double? { get }
}
public protocol CombinedSensorsPortal: AnyObject {
    var lastPower: String? { get }
    var lastPowerValue: Double? { get }
    var lastPowerUnit: String? { get }
    var lastMaxTemp: String? { get }
    var lastMaxTempValue: Double? { get }
    var lastFanSpeed: Double? { get }       // RPM of the fastest fan
    var lastPowerFlow: PowerFlowReading? { get }
}
public protocol CombinedGPUPortal: AnyObject {
    var lastUtilization: Double? { get }    // 0...1
    var lastRenderUtilization: Double? { get }
    var lastANEUtilization: Double? { get }
}
public protocol CombinedDiskPortal: AnyObject {
    var lastPercentage: Double? { get }     // 0...1 of the root drive
    var lastFreeBytes: Int64? { get }
    var lastReadBytes: Int64? { get }       // bytes/s
    var lastWriteBytes: Int64? { get }      // bytes/s
}
public protocol CombinedNetPortal: AnyObject {
    var lastDownloadBytes: Int64? { get }   // bytes/s
    var lastUploadBytes: Int64? { get }     // bytes/s
    var lastPublicIP: String? { get }       // "1.2.3.4 (DE)"
}
public protocol CombinedClockPortal: AnyObject {
    // computed at call time so the row always shows the current minute
    var clockReadings: [ClockReading] { get }
}
public protocol CombinedQuotaPortal: AnyObject {
    // remaining-% snapshots (0...100) for the combined overview's compact strip.
    // nil means the source was not configured / never read successfully. A value
    // survives a failed refresh — check the *UpdatedAt/*Error pair for staleness.
    var kimiFiveHourPct: Double? { get }
    var kimiWeeklyPct: Double? { get }
    var codexFiveHourRemainingPct: Double? { get } // present only while Codex exposes this window
    var codexWeeklyRemainingPct: Double? { get }   // 100 - weekly utilization, or nil
    var kimiError: String? { get }
    var codexError: String? { get }
    // When each source last returned usable data, so the dashboard can dim a
    // stale value instead of blanking it out on a single failed poll.
    var kimiUpdatedAt: Date? { get }
    var codexUpdatedAt: Date? { get }
    // Original reset deadlines. The dashboard formats these against the current
    // time on every refresh, so countdown text advances without extra API polls.
    var kimiFiveHourResetAt: Date? { get }
    var kimiWeeklyResetAt: Date? { get }
    var codexFiveHourResetAt: Date? { get }
    var codexWeeklyResetAt: Date? { get }
    /// Ask the module for a fresh fetch (throttled + de-duplicated by the module).
    /// Called when the overview panel opens, so what you see is what was just read.
    func refreshQuota()
}

// one timezone entry for the combined overview's single-line clock row
public struct ClockReading {
    public var name: String
    public var time: String     // "07:04"
    public var dayDelta: Int    // calendar-day offset vs the local timezone
    public var isLocal: Bool    // true when this entry matches the system timezone

    public init(name: String, time: String, dayDelta: Int, isLocal: Bool = false) {
        self.name = name
        self.time = time
        self.dayDelta = dayDelta
        self.isLocal = isLocal
    }
}

// Latest power-rail readings (in watts) published by the Sensors portal for
// the combined overview's power-flow (sankey) card.
public struct PowerFlowReading {
    public var systemTotal: Double?  // PSTR: whole-system consumption
    public var dcIn: Double?         // PDTR: power drawn from the adapter
    public var cpu: Double?          // IOReport energy model (dead on M5)
    public var gpu: Double?
    public var ane: Double?
    public var ram: Double?
    public var display: Double?      // PBLR: display backlight rail
    public var cpuRail: Double?      // PP0b: CPU cluster supply rail (SMC)
    public var gpuRail: Double?      // PP1b: GPU supply rail (SMC)

    public init() {}
}

open class PortalWrapper: NSStackView, Portal_p {
    public var name: String
    private let header: PortalHeader
    
    public init(_ type: ModuleType, height: CGFloat = Constants.Popup.portalHeight) {
        self.name = type.stringValue
        self.header = PortalHeader(type.stringValue)
        
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: height))
        
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 3
        
        self.orientation = .vertical
        self.distribution = .fillEqually
        self.spacing = Constants.Popup.spacing*2
        self.edgeInsets = NSEdgeInsets(
            top: Constants.Popup.spacing*2,
            left: Constants.Popup.spacing*2,
            bottom: Constants.Popup.spacing*2,
            right: Constants.Popup.spacing*2
        )
        self.addArrangedSubview(self.header)
        
        self.load()
        
        self.heightAnchor.constraint(equalToConstant: Constants.Popup.portalHeight).isActive = true
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func updateLayer() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    
    open func load() {
        self.addArrangedSubview(NSView())
    }
}

public class PortalHeader: NSStackView {
    private let name: String
    
    public init(_ name: String) {
        self.name = name
        
        super.init(frame: NSRect.zero)
        self.heightAnchor.constraint(equalToConstant: 20).isActive = true
        
        let title = NSTextField()
        title.isEditable = false
        title.isSelectable = false
        title.isBezeled = false
        title.wantsLayer = true
        title.textColor = .textColor
        title.backgroundColor = .clear
        title.canDrawSubviewsIntoLayer = true
        title.alignment = .center
        title.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        title.stringValue = localizedString(name)
        
        let settings = NSButton()
        settings.heightAnchor.constraint(equalToConstant: 18).isActive = true
        settings.bezelStyle = .regularSquare
        settings.translatesAutoresizingMaskIntoConstraints = false
        settings.imageScaling = .scaleProportionallyDown
        settings.image = iconFromSymbol(name: "gearshape.fill", scale: .xlarge)
        settings.contentTintColor = .lightGray
        settings.isBordered = false
        settings.action = #selector(self.openSettings)
        settings.target = self
        settings.toolTip = localizedString("Open module settings")
        settings.focusRingType = .none
        
        self.addArrangedSubview(title)
        self.addArrangedSubview(NSView())
        self.addArrangedSubview(settings)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func openSettings() {
        self.window?.setIsVisible(false)
        NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": self.name])
    }
}
