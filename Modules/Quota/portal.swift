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
    // OpenCode Go rows: created up front, shown only while the key exists and
    // the API returned data (module is enabled by default like Codex).
    private var openCodeBars: [QuotaBar?] = [nil, nil, nil]
    private var openCodeFields: [NSTextField?] = [nil, nil, nil]

    // snapshot for the combined overview's compact strip (CombinedQuotaPortal)
    private var snapKimi5h: Double?
    private var snapKimiWeek: Double?
    private var snapCodex5hRem: Double?
    private var snapCodexWeekRem: Double?
    private var snapKimiErr: String?
    private var snapCodexErr: String?
    private var snapOpenCodeErr: String?
    private var snapKimiUpdatedAt: Date?
    private var snapCodexUpdatedAt: Date?
    private var snapOpenCodeUpdatedAt: Date?
    private var snapKimi5hResetAt: Date?
    private var snapKimiWeekResetAt: Date?
    private var snapCodex5hResetAt: Date?
    private var snapCodexWeekResetAt: Date?
    private var snapOpenCode5hRem: Double?
    private var snapOpenCodeWeekRem: Double?
    private var snapOpenCodeMonthRem: Double?
    private var snapOpenCode5hResetAt: Date?
    private var snapOpenCodeWeekResetAt: Date?
    private var snapOpenCodeMonthResetAt: Date?

    /// Set by the module so the dashboard can ask for an on-demand fetch.
    internal var refreshHandler: (() -> Void)?

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
        (self.openCodeBars[0], self.openCodeFields[0]) = Self.makeRow(into: rows, label: "Go 5h")
        (self.openCodeBars[1], self.openCodeFields[1]) = Self.makeRow(into: rows, label: "Go 周")
        (self.openCodeBars[2], self.openCodeFields[2]) = Self.makeRow(into: rows, label: "Go 月")

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

        self.snapKimiErr = value.kimiError
        self.snapKimiUpdatedAt = value.kimiUpdatedAt
        self.snapCodexUpdatedAt = value.codexUpdatedAt
        self.snapOpenCodeUpdatedAt = value.openCodeUpdatedAt

        // --- Kimi (5h + weekly) ---
        if let k = value.kimi {
            if let fiveH = k.fiveHourRemainingPct.map({ max(0, $0) }) {
                self.kimi5hBar?.value = fiveH / 100
                self.kimi5hBar?.color = Self.quotaColor(fiveH)
                self.kimi5hField?.stringValue = "\(Int(fiveH.rounded()))%"
                self.snapKimi5h = fiveH
            } else {
                self.kimi5hBar?.value = 0
                self.kimi5hBar?.color = .lightGray
                self.kimi5hField?.stringValue = "—"
                self.snapKimi5h = nil
            }
            if let week = k.weeklyRemainingPct.map({ max(0, $0) }) {
                self.kimiWeekBar?.value = week / 100
                self.kimiWeekBar?.color = Self.quotaColor(week)
                self.kimiWeekField?.stringValue = "\(Int(week.rounded()))%"
                self.snapKimiWeek = week
            } else {
                self.kimiWeekBar?.value = 0
                self.kimiWeekBar?.color = .lightGray
                self.kimiWeekField?.stringValue = "—"
                self.snapKimiWeek = nil
            }
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
        // The API exposes the 5-hour and weekly windows independently, and either
        // one can disappear server-side. Select by duration so a window coming
        // back cannot land in the other window's row merely by response order;
        // the dashboard hides whichever row has no data.
        self.snapCodex5hRem = value.codex?.fiveHourWindow.map { max(0, 100 - $0.utilization) }
        self.snapCodex5hResetAt = value.codex?.fiveHourWindow?.resetAt
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

        // --- OpenCode Go (rolling 5h + weekly + monthly) ---
        // Same data-driven pattern as Codex: rows light up only for the windows
        // the API actually returned. Percentages arrive as consumed share, so
        // display the remaining side (100 - used) like every other row.
        if let o = value.openCode, o.hasAnyWindow {
            let windows: [(Double?, Date?)] = [
                (o.rollingRemainingPct, o.rollingResetAt),
                (o.weeklyRemainingPct, o.weeklyResetAt),
                (o.monthlyRemainingPct, o.monthlyResetAt)
            ]
            for (idx, pair) in windows.enumerated() {
                if let rem = pair.0 {
                    self.openCodeBars[idx]?.value = rem / 100
                    self.openCodeBars[idx]?.color = Self.quotaColor(rem)
                    self.openCodeFields[idx]?.stringValue = "\(Int(rem.rounded()))%"
                } else {
                    self.openCodeBars[idx]?.value = 0
                    self.openCodeBars[idx]?.color = .lightGray
                    self.openCodeFields[idx]?.stringValue = "—"
                }
                switch idx {
                case 0:
                    self.snapOpenCode5hRem = pair.0
                    self.snapOpenCode5hResetAt = pair.1
                case 1:
                    self.snapOpenCodeWeekRem = pair.0
                    self.snapOpenCodeWeekResetAt = pair.1
                default:
                    self.snapOpenCodeMonthRem = pair.0
                    self.snapOpenCodeMonthResetAt = pair.1
                }
            }
            self.snapOpenCodeErr = nil
        } else if let o = value.openCode, let e = o.error, !e.isEmpty {
            for idx in 0..<3 {
                self.openCodeBars[idx]?.value = 0
                self.openCodeBars[idx]?.color = .systemRed
                self.openCodeFields[idx]?.stringValue = e
            }
            self.snapOpenCodeErr = e
        } else {
            for idx in 0..<3 {
                self.openCodeBars[idx]?.value = 0
                self.openCodeBars[idx]?.color = .lightGray
                self.openCodeFields[idx]?.stringValue = "—"
            }
            self.snapOpenCode5hResetAt = nil
            self.snapOpenCodeWeekResetAt = nil
            self.snapOpenCodeMonthResetAt = nil
            self.snapOpenCodeErr = nil
        }
    }

    // MARK: CombinedQuotaPortal

    public var kimiFiveHourPct: Double? { self.snapKimi5h }
    public var kimiWeeklyPct: Double? { self.snapKimiWeek }
    public var codexFiveHourRemainingPct: Double? { self.snapCodex5hRem }
    public var codexWeeklyRemainingPct: Double? { self.snapCodexWeekRem }
    public var openCodeFiveHourRemainingPct: Double? { self.snapOpenCode5hRem }
    public var openCodeWeeklyRemainingPct: Double? { self.snapOpenCodeWeekRem }
    public var openCodeMonthlyRemainingPct: Double? { self.snapOpenCodeMonthRem }
    public var kimiError: String? { self.snapKimiErr }
    public var codexError: String? { self.snapCodexErr }
    public var openCodeError: String? { self.snapOpenCodeErr }
    public var kimiUpdatedAt: Date? { self.snapKimiUpdatedAt }
    public var codexUpdatedAt: Date? { self.snapCodexUpdatedAt }
    public var openCodeUpdatedAt: Date? { self.snapOpenCodeUpdatedAt }
    public var kimiFiveHourResetAt: Date? { self.snapKimi5hResetAt }
    public var kimiWeeklyResetAt: Date? { self.snapKimiWeekResetAt }
    public var codexFiveHourResetAt: Date? { self.snapCodex5hResetAt }
    public var codexWeeklyResetAt: Date? { self.snapCodexWeekResetAt }
    public var openCodeFiveHourResetAt: Date? { self.snapOpenCode5hResetAt }
    public var openCodeWeeklyResetAt: Date? { self.snapOpenCodeWeekResetAt }
    public var openCodeMonthlyResetAt: Date? { self.snapOpenCodeMonthResetAt }

    public func refreshQuota() {
        self.refreshHandler?()
    }
}
