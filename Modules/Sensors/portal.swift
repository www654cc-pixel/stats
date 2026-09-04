//
//  portal.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 14/01/2024
//  Using Swift 5.0
//  Running on macOS 14.3
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

import AppKit
import Kit

public class Portal: NSStackView, Portal_p, CombinedSensorsPortal {
    public var name: String

    private var container: ScrollableStackView = ScrollableStackView()

    private var list: [String: NSView] = [:]

    // latest snapshots, used by the combined overview summary
    public private(set) var lastPower: String?
    public private(set) var lastPowerValue: Double?
    public private(set) var lastPowerUnit: String?
    public private(set) var lastMaxTemp: String?
    public private(set) var lastMaxTempValue: Double?
    public private(set) var lastFanSpeed: Double?
    public private(set) var lastPowerFlow: PowerFlowReading?

    private var unknownSensorsState: Bool {
        Store.shared.bool(key: "Sensors_unknown", defaultValue: false)
    }

    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: FanValue.percentage.rawValue)) ?? .percentage
    }
    
    init(_ name: ModuleType) {
        self.name = name.stringValue
        
        super.init(frame: NSRect( x: 0, y: 0, width: Constants.Popup.width, height: Constants.Popup.portalHeight))
        
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 3
        
        self.orientation = .vertical
        self.distribution = .fillEqually
        self.widthAnchor.constraint(equalToConstant: Constants.Popup.width).isActive = true
        self.spacing = Constants.Popup.spacing
        self.edgeInsets = NSEdgeInsets(
            top: Constants.Popup.spacing*2,
            left: Constants.Popup.spacing*2,
            bottom: Constants.Popup.spacing*2,
            right: Constants.Popup.spacing
        )
        
        self.container.stackView.spacing = 0
        
        self.addArrangedSubview(PortalHeader(self.name))
        self.addArrangedSubview(self.container)
        
        self.heightAnchor.constraint(equalToConstant: Constants.Popup.portalHeight).isActive = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func updateLayer() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    
    public func setup(_ values: [Sensor_p]? = nil) {
        guard var list = values else { return }
        list = list.filter{ $0.popupState }
        if !self.unknownSensorsState {
            list = list.filter({ $0.group != .unknown })
        }
        
        if !self.list.isEmpty {
            self.container.stackView.subviews.forEach({ $0.removeFromSuperview() })
            self.list = [:]
        }
        
        var width: CGFloat = self.frame.width - self.edgeInsets.left - self.edgeInsets.right
        if list.count >= 4 {
            width -= self.container.scrollWidth ?? Constants.Popup.margins
        }
        list.forEach { s in
            let v = ValueSensorView(s, width: width, callback: {})
            v.update(self.formattedValue(s))
            self.container.stackView.addArrangedSubview(v)
            self.list[s.key] = v
        }
    }
    
    public func usageCallback(_ values: [Sensor_p]) {
        let power = values.first(where: { $0.type == .power && $0.key == "PSTR" }) ?? values.first(where: { $0.type == .power })
        self.lastPower = power?.formattedPopupValue
        self.lastPowerValue = power.map { $0.localValue / 100 }
        self.lastPowerUnit = power?.miniUnit

        var flow = PowerFlowReading()
        for s in values where s.type == .power {
            switch s.key {
            case "PSTR": flow.systemTotal = s.value
            case "PDTR": flow.dcIn = s.value
            case "PBLR": flow.display = s.value
            case "PP0b": flow.cpuRail = s.value
            case "PP1b": flow.gpuRail = s.value
            case "CPU Power": flow.cpu = s.value
            case "GPU Power": flow.gpu = s.value
            case "ANE Power": flow.ane = s.value
            case "RAM Power": flow.ram = s.value
            default: break
            }
        }
        self.lastPowerFlow = flow

        self.lastFanSpeed = values.filter({ $0.type == .fan && !$0.isComputed }).map({ $0.value }).max()

        let temps = values.filter({ $0.type == .temperature && ($0.group == .CPU || $0.group == .GPU) })
        if let hottest = temps.max(by: { $0.value < $1.value }) {
            self.lastMaxTemp = hottest.formattedPopupValue
            self.lastMaxTempValue = hottest.value
        } else {
            self.lastMaxTemp = nil
            self.lastMaxTempValue = nil
        }

        DispatchQueue.main.async(execute: {
            if self.window?.isVisible ?? false {
                values.forEach { (s: Sensor_p) in
                    if let v = self.list[s.key] as? ValueSensorView {
                        v.update(self.formattedValue(s))
                    }
                }
            }
        })
    }

    private func formattedValue(_ sensor: Sensor_p) -> String {
        if let fan = sensor as? Fan {
            return self.fanValueState == .percentage ? "\(fan.percentage)%" : fan.formattedValue
        }
        return sensor.formattedPopupValue
    }

}
