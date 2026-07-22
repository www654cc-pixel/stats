//
//  CalendarPortal.swift
//  Stats
//
//  Full month calendar for the combined overview popup. Purely local: no
//  EventKit or permissions. A stable 6 x 7 grid always shows every day in the
//  month plus adjacent-month context, with festival markers and month paging.
//

import Cocoa
import Kit

internal class CalendarPortal: NSStackView {
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    private let titleField = NSTextField(labelWithString: "")
    private let todayButton = NSButton()
    private let weekdayRow = NSStackView()
    private let gridStack = NSStackView()
    private let footerField = NSTextField(labelWithString: "")

    private var cells: [DayCell] = []
    private var monthAnchor: Date = Date() // first day of the visible month
    private var renderedDay: Date? = nil    // last "today" the grid was rendered against
    private var selectedDate: Date? = nil   // day tapped by the user, shown in the footer

    private let cellHeight: CGFloat = 22
    private let cellSpacing: CGFloat = 2
    private let rows: Int = 6              // stable full-month grid

    private var cal: Calendar { Calendar.current }

    private static let lunarCalendar: Calendar = {
        var c = Calendar(identifier: .chinese)
        c.timeZone = TimeZone.current
        return c
    }()

    // festival names are localization keys; resolved at render time
    private static let gregorianFestivals: [Int: [Int: [String]]] = [
        1: [1: ["New Year's Day"]],
        2: [14: ["Valentine's Day"]],
        3: [8: ["Women's Day"], 12: ["Arbor Day"]],
        4: [1: ["April Fools' Day"]],
        5: [1: ["Labour Day"], 4: ["Youth Day"]],
        6: [1: ["Children's Day"]],
        7: [1: ["CPC Founding Day"]],
        8: [1: ["Army Day"]],
        9: [10: ["Teachers' Day"]],
        10: [1: ["National Day"], 31: ["Halloween"]],
        12: [24: ["Christmas Eve"], 25: ["Christmas Day"]]
    ]

    private static let lunarFestivals: [Int: [Int: [String]]] = [
        1: [1: ["Spring Festival"], 15: ["Lantern Festival"]],
        5: [5: ["Dragon Boat Festival"]],
        7: [7: ["Qixi Festival"], 15: ["Ghost Festival"]],
        8: [15: ["Mid-Autumn Festival"]],
        9: [9: ["Double Ninth Festival"]],
        12: [8: ["Laba Festival"]]
    ]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.wantsLayer = true
        self.applyCardStyle()

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = 8
        self.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        // header: ‹ title › today
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let prev = self.navButton("‹", tooltip: localizedString("Previous month"), action: #selector(self.goPrevWeek))
        let next = self.navButton("›", tooltip: localizedString("Next month"), action: #selector(self.goNextWeek))

        self.titleField.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        self.titleField.textColor = .labelColor
        self.titleField.alignment = .center

        self.todayButton.title = localizedString("Today")
        self.todayButton.bezelStyle = .inline
        self.todayButton.controlSize = .small
        self.todayButton.font = NSFont.systemFont(ofSize: 11)
        self.todayButton.target = self
        self.todayButton.action = #selector(self.goToday)
        self.todayButton.toolTip = localizedString("Back to today")

        header.addArrangedSubview(prev)
        header.addArrangedSubview(self.titleField)
        header.addArrangedSubview(next)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(self.todayButton)
        self.addArrangedSubview(header)

        // weekday symbols row (respects the locale's first weekday)
        self.weekdayRow.orientation = .horizontal
        self.weekdayRow.distribution = .fillEqually
        self.weekdayRow.spacing = self.cellSpacing
        for i in 0..<7 {
            let idx = (self.cal.firstWeekday - 1 + i) % 7
            let label = NSTextField(labelWithString: self.cal.shortWeekdaySymbols[idx])
            label.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = Design.secondaryTextColor
            label.alignment = .center
            // fillEqually only stretches arranged views whose hugging priority
            // doesn't resist; text fields hug at 250, so lower it explicitly —
            // otherwise the whole row shrinks to its intrinsic width (the
            // pre-existing right-clumped header bug).
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            self.weekdayRow.addArrangedSubview(label)
        }
        self.addArrangedSubview(self.weekdayRow)
        // belt and braces: pin the row to the card's content width
        self.weekdayRow.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -(self.edgeInsets.left + self.edgeInsets.right)).isActive = true

        // 6 rows x 7 days always covers a complete Gregorian month.
        self.gridStack.orientation = .vertical
        self.gridStack.distribution = .fillEqually
        self.gridStack.spacing = self.cellSpacing
        for _ in 0..<self.rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = self.cellSpacing
            for _ in 0..<7 {
                let cell = DayCell()
                cell.heightAnchor.constraint(equalToConstant: self.cellHeight).isActive = true
                row.addArrangedSubview(cell)
                self.cells.append(cell)
            }
            self.gridStack.addArrangedSubview(row)
        }
        self.addArrangedSubview(self.gridStack)

        // footer: today's full date + festival, so "today" is visible even
        // while browsing other weeks
        self.footerField.font = NSFont.systemFont(ofSize: 10.5)
        self.footerField.textColor = Design.secondaryTextColor
        self.footerField.alignment = .right
        self.addArrangedSubview(self.footerField)

        self.goToday()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not implemented")
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    internal func setSize(width: CGFloat, height: CGFloat?) {
        self.widthConstraint?.isActive = false
        self.widthConstraint = self.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint?.isActive = true
        self.heightConstraint?.isActive = false
        self.heightConstraint = height.map { self.heightAnchor.constraint(equalToConstant: $0) }
        self.heightConstraint?.isActive = true
    }

    // called by the overview on appear and once per second while visible;
    // re-renders only when the calendar day has rolled over
    internal func refresh() {
        let now = Date()
        if self.renderedDay == nil || !self.cal.isDate(now, inSameDayAs: self.renderedDay!) {
            self.renderGrid()
        }
    }

    // MARK: - navigation

    @objc private func goPrevWeek() { self.shiftMonths(-1) }
    @objc private func goNextWeek() { self.shiftMonths(1) }
    @objc private func goToday() {
        self.selectedDate = nil
        self.monthAnchor = self.startOfMonth(Date())
        self.renderGrid()
    }

    private func shiftMonths(_ value: Int) {
        guard let shifted = self.cal.date(byAdding: .month, value: value, to: self.monthAnchor) else { return }
        self.monthAnchor = self.startOfMonth(shifted)
        self.renderGrid()
    }

    private func startOfMonth(_ date: Date) -> Date {
        let components = self.cal.dateComponents([.year, .month], from: date)
        return self.cal.date(from: components) ?? date
    }

    // start of the week containing `date`, aligned to the locale's first weekday
    private func startOfWeek(_ date: Date) -> Date {
        let comps = self.cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.cal.date(from: comps) ?? date
    }

    // MARK: - rendering

    private func renderGrid() {
        let now = Date()
        self.renderedDay = now

        self.monthAnchor = self.startOfMonth(self.monthAnchor)
        let monthFmt = DateFormatter()
        monthFmt.setLocalizedDateFormatFromTemplate("yMMMM")
        self.titleField.stringValue = monthFmt.string(from: self.monthAnchor)

        let currentAnchor = self.startOfMonth(now)
        self.todayButton.isHidden = self.cal.isDate(self.monthAnchor, equalTo: currentAnchor, toGranularity: .month)

        let gridStart = self.startOfWeek(self.monthAnchor)

        for (i, cell) in self.cells.enumerated() {
            guard let date = self.cal.date(byAdding: .day, value: i, to: gridStart) else { continue }
            let isToday = self.cal.isDate(date, inSameDayAs: now)
            let isSelected = self.selectedDate.map { self.cal.isDate(date, inSameDayAs: $0) } ?? false
            let weekend = self.cal.isDateInWeekend(date)
            let inMonth = self.cal.isDate(date, equalTo: self.monthAnchor, toGranularity: .month)
            cell.configure(
                date: date,
                day: self.cal.component(.day, from: date),
                inMonth: inMonth,
                isToday: isToday,
                isSelected: isSelected,
                weekend: weekend,
                festivals: self.festivals(for: date),
                onSelect: { [weak self] in self?.select($0) }
            )
        }

        // footer: the selected day if any, otherwise today (with festivals)
        let fullFmt = DateFormatter()
        fullFmt.setLocalizedDateFormatFromTemplate("MEdEEE")
        var footer: String
        if let selected = self.selectedDate, !self.cal.isDate(selected, inSameDayAs: now) {
            footer = fullFmt.string(from: selected)
        } else {
            footer = "\(localizedString("Today")) \(fullFmt.string(from: now))"
        }
        let shownFestivals = self.festivals(for: self.selectedDate ?? now)
        if !shownFestivals.isEmpty {
            footer += " · " + shownFestivals.joined(separator: ", ")
        }
        self.footerField.stringValue = footer
    }

    // tap on a day: highlight it and scroll the window so that week is visible
    private func select(_ date: Date) {
        self.selectedDate = date
        if !self.cal.isDate(date, equalTo: self.monthAnchor, toGranularity: .month) {
            self.monthAnchor = self.startOfMonth(date)
        }
        self.renderGrid()
    }

    private func navButton(_ title: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = title
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        button.contentTintColor = Design.secondaryTextColor
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    // MARK: - festivals

    private func festivals(for date: Date) -> [String] {
        var result: [String] = []
        let g = self.cal.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = g.year, let month = g.month, let day = g.day else { return result }

        if let names = CalendarPortal.gregorianFestivals[month]?[day] {
            result.append(contentsOf: names)
        }

        // Qingming (solar term): falls on Apr 4 or 5 in 2001-2099
        if month == 4 && (2001...2099).contains(year) {
            let y = year % 100
            let qingming = Int(Double(y) * 0.2422 + 4.81) - Int((y - 1) / 4)
            if day == qingming { result.append("Qingming Festival") }
        }

        // Mother's Day: 2nd Sunday of May; Father's Day: 3rd Sunday of June
        if g.weekday == 1 {
            if month == 5 && (8...14).contains(day) { result.append("Mother's Day") }
            if month == 6 && (15...21).contains(day) { result.append("Father's Day") }
        }

        // Chinese lunar festivals (leap months do not repeat the festival)
        if let lunar = self.lunarComponents(from: date), !lunar.isLeap {
            if let names = CalendarPortal.lunarFestivals[lunar.month]?[lunar.day] {
                result.append(contentsOf: names)
            }
            // Chinese New Year's Eve: the day before lunar 1/1
            if let tomorrow = self.cal.date(byAdding: .day, value: 1, to: date),
               let t = self.lunarComponents(from: tomorrow),
               t.month == 1 && t.day == 1 && !t.isLeap {
                result.append("Chinese New Year's Eve")
            }
        }

        return result.map { localizedString($0) }
    }

    // DateComponents.isLeapMonth needs macOS 14; below it the leap-month
    // filter is skipped, so a festival may also show in a leap month
    private func lunarComponents(from date: Date) -> (month: Int, day: Int, isLeap: Bool)? {
        if #available(macOS 14, *) {
            let c = CalendarPortal.lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: date)
            guard let m = c.month, let d = c.day else { return nil }
            return (m, d, c.isLeapMonth == true)
        } else {
            let c = CalendarPortal.lunarCalendar.dateComponents([.month, .day], from: date)
            guard let m = c.month, let d = c.day else { return nil }
            return (m, d, false)
        }
    }
}

// MARK: - day cell

private class DayCell: NSView {
    private let highlight = NSView()
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    private var date: Date? = nil
    private var onSelect: ((Date) -> Void)? = nil
    private var inMonth = true
    private var isToday = false
    private var isSelected = false
    private var weekend = false
    private var hasFestival = false

    init() {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor

        self.highlight.wantsLayer = true
        self.highlight.layer?.cornerRadius = 11
        self.addSubview(self.highlight)

        self.label.alignment = .center
        self.label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        self.addSubview(self.label)

        self.dot.wantsLayer = true
        self.dot.layer?.cornerRadius = 2
        self.dot.layer?.backgroundColor = Design.warn.cgColor
        self.dot.isHidden = true
        self.addSubview(self.dot)

        self.highlight.translatesAutoresizingMaskIntoConstraints = false
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.highlight.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.highlight.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.highlight.widthAnchor.constraint(equalToConstant: 30),
            self.highlight.heightAnchor.constraint(equalToConstant: 22),
            self.label.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.label.centerYAnchor.constraint(equalTo: self.centerYAnchor, constant: -1),
            self.dot.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.dot.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -3),
            self.dot.widthAnchor.constraint(equalToConstant: 4),
            self.dot.heightAnchor.constraint(equalToConstant: 4)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(self.handleClick(_:)))
        self.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not implemented")
    }

    func configure(date: Date, day: Int, inMonth: Bool, isToday: Bool, isSelected: Bool, weekend: Bool, festivals: [String], onSelect: @escaping (Date) -> Void) {
        self.date = date
        self.onSelect = onSelect
        self.label.stringValue = "\(day)"
        self.inMonth = inMonth
        self.isToday = isToday
        self.isSelected = isSelected
        self.weekend = weekend
        self.hasFestival = inMonth && !festivals.isEmpty
        self.toolTip = festivals.isEmpty ? nil : festivals.joined(separator: ", ")
        self.applyStyle()
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
        guard let date = self.date else { return }
        self.onSelect?(date)
    }

    override func resetCursorRects() {
        self.discardCursorRects()
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }

    private func applyStyle() {
        self.layer?.borderWidth = 0
        self.layer?.backgroundColor = NSColor.clear.cgColor
        if self.isToday {
            self.highlight.layer?.backgroundColor = Design.accent.cgColor
            self.label.textColor = .white
            self.label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        } else if self.isSelected {
            self.highlight.layer?.backgroundColor = Design.accent.withAlphaComponent(0.18).cgColor
            self.label.textColor = Design.accent
            self.label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        } else {
            self.highlight.layer?.backgroundColor = NSColor.clear.cgColor
            self.label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            if !self.inMonth {
                self.label.textColor = Design.mutedTextColor
            } else if self.hasFestival {
                self.label.textColor = Design.warn
            } else if self.weekend {
                self.label.textColor = Design.secondaryTextColor
            } else {
                self.label.textColor = .labelColor
            }
        }
        self.dot.isHidden = !self.hasFestival
        self.dot.layer?.backgroundColor = self.isToday ? NSColor.white.cgColor : Design.warn.cgColor
    }

    override func updateLayer() {
        self.applyStyle()
    }
}
