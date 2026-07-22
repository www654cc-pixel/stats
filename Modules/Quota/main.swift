//
//  main.swift
//  Quota
//
//  Quota module for Stats: shows Kimi For Coding plan quota and Codex
//  (ChatGPT) subscription quota in the menu bar + popup.
//

import Cocoa
import Kit

public class Quota: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private var reader: QuotaReader? = nil

    public init() {
        self.settingsView = Settings(.quota)
        self.popupView = Popup(.quota)
        self.portalView = Portal(.quota)

        super.init(
            moduleType: .quota,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView
        )
        guard self.available else { return }

        self.reader = QuotaReader(.quota) { [weak self] value in
            self?.quotaCallback(value)
        }

        self.settingsView.callback = { [weak self] in
            self?.reader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.reader?.setInterval(value)
        }

        self.setReaders([self.reader])
    }

    private func quotaCallback(_ value: QuotaData?) {
        guard let value else { return }
        guard self.enabled else { return }

        self.popupView.loadCallback(value)
        self.portalView.loadCallback(value)

        // Compact menu-bar text widget: "K35% C12% A80%" (remaining %)
        var parts: [String] = []
        if let k = value.kimi, let p = k.fiveHourRemainingPct {
            parts.append("K\(Int(p.rounded()))%")
        }
        if let c = value.codex, let w = c.windows.first {
            parts.append("C\(Int(w.utilization.rounded()))%")
        }
        let text = parts.isEmpty ? "—" : parts.joined(separator: " ")

        self.menuBar.widgets.filter({ $0.isActive }).forEach { (w: SWidget) in
            if let tw = w.item as? TextWidget {
                tw.setValue(text)
            }
        }
    }
}
