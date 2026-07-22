//
//  LauncherPortal.swift
//  Stats
//
//  Quick-launch panel for user-selected applications inside the combined
//  overview popup. Favorites are persisted in Store.shared under
//  "launcher_favorites" as an array of .app bundle paths.
//

import Cocoa
import Kit

internal class LauncherPortal: NSStackView {
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    internal var onResize: (() -> Void)?

    private let titleField = NSTextField(labelWithString: localizedString("Launchpad"))
    private let contentStack = NSStackView()

    private let iconSize: CGFloat = 26

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.wantsLayer = true
        self.applyCardStyle()

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = 4
        self.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        self.titleField.font = Design.labelMediumFont
        self.titleField.textColor = .labelColor

        // single-line layout: rocket icon + title on the left, app icons flowing after
        let header = NSStackView()
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 12

        let rocket = NSImageView()
        rocket.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
        rocket.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        rocket.contentTintColor = .systemIndigo
        rocket.setContentHuggingPriority(.required, for: .horizontal)

        let titleBox = NSStackView()
        titleBox.orientation = .horizontal
        titleBox.alignment = .centerY
        titleBox.spacing = 5
        titleBox.addArrangedSubview(rocket)
        titleBox.addArrangedSubview(self.titleField)

        self.contentStack.orientation = .horizontal
        self.contentStack.distribution = .fill
        self.contentStack.alignment = .centerY
        self.contentStack.spacing = 6
        header.addArrangedSubview(titleBox)
        header.addArrangedSubview(self.contentStack)
        header.addArrangedSubview(NSView())
        self.addArrangedSubview(header)

        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: 0)
        self.heightConstraint?.isActive = true

        self.rebuild()

        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .launcherFavoritesChanged, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func updateLayer() {
        self.applyCardStyle()
    }

    internal func setWidth(_ width: CGFloat) {
        self.widthConstraint?.isActive = false
        self.widthConstraint = self.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint?.isActive = true
        self.setFrameSize(NSSize(width: width, height: self.frame.height))
        self.rebuild()
    }

    @objc private func rebuild() {
        self.contentStack.subviews.forEach { $0.removeFromSuperview() }

        let paths = Store.shared.array(key: "launcher_favorites", defaultValue: []) as? [String] ?? []
        let apps = paths.compactMap { self.appInfo(at: $0) }

        if apps.isEmpty {
            let label = NSTextField(labelWithString: localizedString("Add apps in settings"))
            label.textColor = Design.mutedTextColor
            label.font = NSFont.systemFont(ofSize: 11)
            self.contentStack.addArrangedSubview(label)
        } else {
            apps.forEach { self.contentStack.addArrangedSubview(self.appTile($0)) }
        }

        let h = self.edgeInsets.top + self.iconSize + 8 + self.edgeInsets.bottom
        self.heightConstraint?.constant = h
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.onResize?()
    }

    private func appInfo(at path: String) -> (url: URL, name: String, icon: NSImage)? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: self.iconSize, height: self.iconSize)
        let name = url.deletingPathExtension().lastPathComponent
        return (url, name, icon)
    }

    private func appTile(_ app: (url: URL, name: String, icon: NSImage)) -> NSView {
        let view = HoverTile()
        view.orientation = .horizontal
        view.alignment = .centerY
        view.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        view.toolTip = app.name

        let imageView = NSImageView(image: app.icon)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.widthAnchor.constraint(equalToConstant: self.iconSize).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: self.iconSize).isActive = true
        view.addArrangedSubview(imageView)

        let click = NSClickGestureRecognizer(target: self, action: #selector(self.handleClick(_:)))
        view.addGestureRecognizer(click)
        view.identifier = NSUserInterfaceItemIdentifier(rawValue: app.url.path)

        return view
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
        guard let path = sender.view?.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        if let window = self.window {
            window.setIsVisible(false)
        }
    }
}

private class HoverTile: NSStackView {
    private var trackingArea: NSTrackingArea?

    override func updateLayer() {
        super.updateLayer()
        self.layer?.cornerRadius = 6
    }

    override func mouseEntered(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        self.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = self.trackingArea {
            self.removeTrackingArea(ta)
        }
        let ta = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways, .mouseMoved], owner: self, userInfo: nil)
        self.addTrackingArea(ta)
        self.trackingArea = ta
    }
}

extension Notification.Name {
    static let launcherFavoritesChanged = Notification.Name("launcherFavoritesChanged")
}
