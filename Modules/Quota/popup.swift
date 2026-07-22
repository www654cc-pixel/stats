//
//  popup.swift
//  Quota
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private var kimi5hField: NSTextField?
    private var kimiWeeklyField: NSTextField?
    private var kimiUsdField: NSTextField?
    private var kimiResetField: NSTextField?
    private var kimiPlanField: NSTextField?
    private var codexPrimaryField: NSTextField?
    private var codexSecondaryField: NSTextField?
    private var codexResetField: NSTextField?
    private var updatedField: NSTextField?
    private var errorField: NSTextField?

    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = Constants.Popup.spacing

        self.buildUI()
        self.recalculateHeight()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func appear() {
        super.appear()
        self.recalculateHeight()
    }

    private func valueField() -> NSTextField {
        let f = NSTextField(labelWithString: "—")
        f.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        f.textColor = .textColor
        f.alignment = .right
        return f
    }

    private func buildUI() {
        self.kimi5hField = self.valueField()
        self.kimiWeeklyField = self.valueField()
        self.kimiUsdField = self.valueField()
        self.kimiResetField = self.valueField()
        self.kimiPlanField = self.valueField()
        self.codexPrimaryField = self.valueField()
        self.codexSecondaryField = self.valueField()
        self.codexResetField = self.valueField()
        self.updatedField = self.valueField()
        self.errorField = NSTextField(wrappingLabelWithString: "")
        self.errorField?.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        self.errorField?.textColor = .systemRed
        self.errorField?.alignment = .left
        self.errorField?.preferredMaxLayoutWidth = Constants.Popup.width - (Constants.Popup.margins * 2)

        let kimi = PreferencesSection([
            PreferencesRow("Kimi · 5 小时额度", component: self.kimi5hField!),
            PreferencesRow("Kimi · 周额度", component: self.kimiWeeklyField!),
            PreferencesRow("Kimi · 5h 剩余/上限", component: self.kimiUsdField!),
            PreferencesRow("Kimi · 重置时间", component: self.kimiResetField!),
            PreferencesRow("Kimi · 套餐 / 状态", component: self.kimiPlanField!)
        ])

        let codex = PreferencesSection([
            PreferencesRow("Codex · 主窗口", component: self.codexPrimaryField!),
            PreferencesRow("Codex · 次窗口", component: self.codexSecondaryField!),
            PreferencesRow("Codex · 重置时间", component: self.codexResetField!)
        ])

        let meta = PreferencesSection([
            PreferencesRow("最近更新", component: self.updatedField!)
        ])

        self.addArrangedSubview(kimi)
        self.addArrangedSubview(codex)
        self.addArrangedSubview(meta)
        self.addArrangedSubview(self.errorField!)
    }

    internal func loadCallback(_ value: QuotaData?) {
        guard let value else { return }

        if let k = value.kimi {
            self.kimi5hField?.stringValue = k.fiveHourRemainingPct != nil
                ? "\(Int((k.fiveHourRemainingPct ?? 0).rounded()))%"
                  + (k.fiveHourRemaining != nil ? "  (剩 \(Int(k.fiveHourRemaining!)))" : "")
                : "—"
            self.kimiWeeklyField?.stringValue = k.weeklyRemainingPct != nil
                ? "\(Int((k.weeklyRemainingPct ?? 0).rounded()))%"
                  + (k.weeklyRemaining != nil ? "  (剩 \(Int(k.weeklyRemaining!)))" : "")
                : "—"
            if let r = k.fiveHourRemaining, let l = k.fiveHourLimit {
                self.kimiUsdField?.stringValue = "\(Int(r)) / \(Int(l))"
            } else {
                self.kimiUsdField?.stringValue = "—"
            }
            self.kimiResetField?.stringValue = k.fiveHourReset ?? k.weeklyReset ?? "—"
            var plan = k.planTier ?? ""
            if let s = k.accountStatus, !s.isEmpty {
                plan = plan.isEmpty ? s : "\(plan) (\(s))"
            }
            self.kimiPlanField?.stringValue = plan.isEmpty ? "—" : plan
        } else {
            self.kimi5hField?.stringValue = "未配置"
            self.kimiWeeklyField?.stringValue = "未配置"
            self.kimiUsdField?.stringValue = "—"
            self.kimiResetField?.stringValue = "—"
            self.kimiPlanField?.stringValue = "—"
        }

        if let c = value.codex {
            if c.windows.indices.contains(0) {
                let w = c.windows[0]
                self.codexPrimaryField?.stringValue = "\(Int(w.utilization.rounded()))%"
                    + (w.resetsAt != nil ? "  (重置 \(w.resetsAt!))" : "")
                self.codexResetField?.stringValue = w.resetsAt ?? "—"
            } else {
                self.codexPrimaryField?.stringValue = "—"
                self.codexResetField?.stringValue = "—"
            }
            if c.windows.indices.contains(1) {
                let w = c.windows[1]
                self.codexSecondaryField?.stringValue = "\(Int(w.utilization.rounded()))%"
            } else {
                self.codexSecondaryField?.stringValue = "—"
            }
        } else {
            self.codexPrimaryField?.stringValue = "—"
            self.codexSecondaryField?.stringValue = "—"
            self.codexResetField?.stringValue = "—"
        }

        if let updated = value.updatedAt {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            self.updatedField?.stringValue = fmt.string(from: updated)
        }

        self.errorField?.stringValue = value.error ?? (value.codex?.error ?? "")
        self.recalculateHeight()
    }

    private func recalculateHeight() {
        var h: CGFloat = 0
        for v in self.arrangedSubviews {
            h += v.frame.height + self.spacing
        }
        if h > 0 { h -= self.spacing }
        let minH: CGFloat = 300
        let finalH = max(h, minH)
        if self.frame.size.height != finalH {
            self.setFrameSize(NSSize(width: self.frame.width, height: finalH))
            self.sizeCallback?(self.frame.size)
        }
    }
}
