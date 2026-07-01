//
//  portal.swift
//  Clock
//
//  Created by Serhiy Mytrovtsiy on 28/12/2023
//  Using Swift 5.0
//  Running on macOS 14.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import AppKit
import Kit

public class Portal: NSStackView, Portal_p {
    public var isWide: Bool { true }
    public var name: String
    public var onResize: (() -> Void)?
    
    private let header: PortalHeader
    private var grid: NSGridView?
    private var list: [Clock_t] = []
    
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    
    private let cardHeight: CGFloat = 50

    init(_ module: ModuleType, list: [Clock_t]) {
        self.name = module.stringValue
        self.header = PortalHeader(module.stringValue)

        super.init(frame: NSRect( x: 0, y: 0, width: Constants.Popup.width, height: Constants.Popup.portalHeight))

        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 3

        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = Constants.Popup.spacing*2
        self.edgeInsets = NSEdgeInsets(
            top: Constants.Popup.spacing*2,
            left: Constants.Popup.spacing*2,
            bottom: Constants.Popup.spacing*2,
            right: Constants.Popup.spacing*2
        )

        self.addArrangedSubview(self.header)

        self.widthConstraint = self.widthAnchor.constraint(equalToConstant: Constants.Popup.width)
        self.widthConstraint?.isActive = true

        self.callback(list)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    public func setWideWidth(_ width: CGFloat) {
        self.widthConstraint?.constant = width
        self.layoutSubtreeIfNeeded()
        self.rebuildGrid()
    }

    private func rebuildGrid() {
        self.grid?.removeFromSuperview()
        self.grid = nil
        self.heightConstraint?.isActive = false
        self.heightConstraint = nil

        let count = self.list.count
        guard count > 0 else { return }

        // tile clocks in a grid so every configured timezone is visible at once,
        // without a vertical scrollbar clipping the right edge of each row.
        let columns: Int
        switch count {
        case 1: columns = 1
        case 2: columns = 2
        case 3, 4: columns = 2
        default: columns = 3
        }
        let rows = (count + columns - 1) / columns

        let grid = NSGridView()
        grid.rowSpacing = Constants.Popup.spacing
        grid.columnSpacing = Constants.Popup.spacing

        let availableWidth = self.frame.width - self.edgeInsets.left - self.edgeInsets.right
        let totalSpacing = CGFloat(columns - 1) * Constants.Popup.spacing
        let cardWidth = floor((availableWidth - totalSpacing) / CGFloat(columns))

        var rowViews: [NSView] = []
        for clock in self.list {
            let view = ClockView(width: cardWidth, clock: clock)
            rowViews.append(view)
            if rowViews.count == columns {
                grid.addRow(with: rowViews)
                rowViews = []
            }
        }
        if !rowViews.isEmpty {
            while rowViews.count < columns { rowViews.append(NSView()) }
            grid.addRow(with: rowViews)
        }

        for i in 0..<columns {
            grid.column(at: i).width = cardWidth
            grid.column(at: i).xPlacement = .fill
        }
        for r in 0..<grid.numberOfRows {
            grid.row(at: r).height = self.cardHeight
            grid.row(at: r).yPlacement = .fill
        }

        self.addArrangedSubview(grid)
        self.grid = grid

        let contentHeight = CGFloat(rows) * self.cardHeight + CGFloat(max(rows - 1, 0)) * Constants.Popup.spacing
        let totalHeight = self.edgeInsets.top + self.edgeInsets.bottom + 20 + self.spacing + contentHeight
        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: totalHeight)
        self.heightConstraint?.isActive = true

        self.onResize?()
    }

    public func callback(_ list: [Clock_t]) {
        var sorted = list.sorted(by: { $0.popupIndex < $1.popupIndex })
        sorted = sorted.filter({ $0.popupState })
        self.list = sorted
        self.rebuildGrid()
    }
}
