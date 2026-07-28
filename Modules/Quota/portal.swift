//
//  portal.swift
//  Quota
//
//  Combined-overview portal for the Quota module.
//  Renders each quota as a horizontal progress bar (like the other
//  module portals) with a colour that tracks the remaining percentage.
//

import Cocoa
import Kit

// MARK: - Lightweight horizontal progress bar

private class QuotaBar: NSView {
    private let track = NSView()
    private let fill = NSView()
    private var fillWidth: NSLayoutConstraint?

    var color: NSColor = .systemGreen {
        didSet { self.fill.layer?.backgroundColor = self.color.cgColor }
    }
    var value: Double = 0 {  // 0...1
        didSet { self.apply() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true

        self.track.wantsLayer = true
        self.track.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        self.track.layer?.cornerRadius = 3
        self.addSubview(self.track)
        self.track.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.track.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.track.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.track.topAnchor.constraint(equalTo: self.topAnchor),
            self.track.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        self.fill.wantsLayer = true
        self.fill.layer?.backgroundColor = self.color.cgColor
        self.fill.layer?.cornerRadius = 3
        self.track.addSubview(self.fill)
        self.fill.translatesAutoresizingMaskIntoConstraints = false
        self.fill.leadingAnchor.constraint(equalTo: self.track.leadingAnchor).isActive = true
        self.fill.topAnchor.constraint(equalTo: self.track.topAnchor).isActive = true
        self.fill.bottomAnchor.constraint(equalTo: self.track.bottomAnchor).isActive = true
        self.fillWidth = self.fill.widthAnchor.constraint(equalTo: self.track.widthAnchor, multiplier: 1)
        self.fillWidth?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func apply() {
        let v = min(max(self.value, 0), 1)
        self.fillWidth?.isActive = false
        self.fillWidth = self.fill.widthAnchor.constraint(equalTo: self.track.widthAnchor, multiplier: CGFloat(v))
        self.fillWidth?.isActive = true
        self.fill.layer?.backgroundColor = self.color.cgColor
    }
}

// MARK: - Portal

public class Portal: PortalWrapper, CombinedQuotaPortal {
    private var kimi5hBar: QuotaBar?
    private var kimi5hField: NSTextField?
    private var kimiWeekBar: QuotaBar?
    private var kimiWeekField: NSTextField?
    private var codexBar: QuotaBar?
    private var codexField: NSTextField?

    // snapshot for the combined overview's compact strip (CombinedQuotaPortal)
    private var snapKimi5h: Double?
    private var snapKimiWeek: Double?
    private var snapCodex5hRem: Double?
    private var snapCodexWeekRem: Double?
    private var snapCodexErr: String?
    private var snapKimi5hResetAt: Date?
    private var snapKimiWeekResetAt: Date?
    private var snapCodexWeekResetAt: Date?

    public override func load() {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.distribution = .fillEqually
        rows.spacing = Constants.Popup.spacing * 2
        rows.edgeInsets = NSEdgeInsets(
            top: Constants.Popup.spacing,
            left: Constants.Popup.spacing * 2,
            bottom: Constants.Popup.spacing,
            right: Constants.Popup.spacing * 2
        )

        (self.kimi5hBar, self.kimi5hField)   = Self.makeRow(into: rows, label: "Kimi 5h")
        (self.kimiWeekBar, self.kimiWeekField) = Self.makeRow(into: rows, label: "Kimi 周")
        (self.codexBar, self.codexField)     = Self.makeRow(into: rows, label: localizedString("Quota Codex weekly"))

        self.addArrangedSubview(rows)
    }

    private static func makeRow(into parent: NSStackView, label: String) -> (QuotaBar, ValueField) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 8

        let lab = LabelField(label)
        lab.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        lab.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let bar = QuotaBar()
        bar.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let val = ValueField("—")
        val.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        val.alignment = .right
        val.widthAnchor.constraint(equalToConstant: 46).isActive = true

        row.addArrangedSubview(lab)
        row.addArrangedSubview(bar)
        row.addArrangedSubview(val)
        parent.addArrangedSubview(row)
        return (bar, val)
    }

    /// Traffic-light colour for remaining-percentage (0–100).
    private static func quotaColor(_ remainingPct: Double) -> NSColor {
        if remainingPct > 50  { return .systemGreen }
        if remainingPct >= 20 { return .systemOrange }
        return .systemRed
    }

    internal func loadCallback(_ value: QuotaData?) {
        guard let value else { return }

        // --- Kimi (5h + weekly) ---
        if let k = value.kimi {
            let fiveH = k.fiveHourRemainingPct.map { max(0, $0) } ?? 0
            let week  = k.weeklyRemainingPct.map { max(0, $0) } ?? 0
            self.kimi5hBar?.value = fiveH / 100
            self.kimi5hBar?.color = Self.quotaColor(fiveH)
            self.kimi5hField?.stringValue = "\(Int(fiveH.rounded()))%"
            self.kimiWeekBar?.value = week / 100
            self.kimiWeekBar?.color = Self.quotaColor(week)
            self.kimiWeekField?.stringValue = "\(Int(week.rounded()))%"
            self.snapKimi5h = fiveH
            self.snapKimiWeek = week
            self.snapKimi5hResetAt = k.fiveHourResetAt
            self.snapKimiWeekResetAt = k.weeklyResetAt
        } else {
            for (bar, field) in [(self.kimi5hBar, self.kimi5hField),
                                 (self.kimiWeekBar, self.kimiWeekField)] {
                bar?.value = 0
                bar?.color = .lightGray
                field?.stringValue = "—"
            }
            self.snapKimi5h = nil
            self.snapKimiWeek = nil
            self.snapKimi5hResetAt = nil
            self.snapKimiWeekResetAt = nil
        }

        // --- Codex ---
        // The API historically exposed both 5-hour and weekly windows. Select
        // by duration so restoring the 5-hour window cannot replace the weekly
        // value in the combined dashboard merely by changing response order.
        self.snapCodex5hRem = value.codex?.fiveHourWindow.map { max(0, 100 - $0.utilization) }
        if let c = value.codex, let w = c.weeklyWindow {
            let rem = max(0, 100 - w.utilization)
            self.codexBar?.value = rem / 100
            self.codexBar?.color = Self.quotaColor(rem)
            self.codexField?.stringValue = "\(Int(rem.rounded()))%"
            self.snapCodexWeekRem = rem
            self.snapCodexWeekResetAt = w.resetAt
            self.snapCodexErr = nil
        } else if let c = value.codex, let e = c.error, !e.isEmpty {
            self.codexBar?.value = 0
            self.codexBar?.color = .systemRed
            self.codexField?.stringValue = e
            self.snapCodexErr = e
            self.snapCodexWeekRem = nil
            self.snapCodexWeekResetAt = nil
        } else {
            self.codexBar?.value = 0
            self.codexBar?.color = .lightGray
            self.codexField?.stringValue = "—"
            self.snapCodexWeekRem = nil
            self.snapCodexWeekResetAt = nil
            self.snapCodexErr = nil
        }
    }

    // MARK: CombinedQuotaPortal

    public var kimiFiveHourPct: Double? { self.snapKimi5h }
    public var kimiWeeklyPct: Double? { self.snapKimiWeek }
    public var codexFiveHourRemainingPct: Double? { self.snapCodex5hRem }
    public var codexWeeklyRemainingPct: Double? { self.snapCodexWeekRem }
    public var codexError: String? { self.snapCodexErr }
    public var kimiFiveHourResetAt: Date? { self.snapKimi5hResetAt }
    public var kimiWeeklyResetAt: Date? { self.snapKimiWeekResetAt }
    public var codexWeeklyResetAt: Date? { self.snapCodexWeekResetAt }
}
