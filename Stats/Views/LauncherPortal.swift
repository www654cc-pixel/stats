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

    private let iconSize: CGFloat = 36
    private let columns: Int = 4

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 3

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = Constants.Popup.spacing
        self.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        self.titleField.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let header = NSStackView()
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 6
        header.addArrangedSubview(self.titleField)
        header.addArrangedSubview(NSView())
        self.addArrangedSubview(header)

        self.contentStack.orientation = .vertical
        self.contentStack.distribution = .fill
        self.contentStack.alignment = .width
        self.contentStack.spacing = Constants.Popup.spacing * 2
        self.addArrangedSubview(self.contentStack)

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
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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

        guard !apps.isEmpty else {
            self.showEmpty()
            return
        }

        let innerWidth = self.frame.width - self.edgeInsets.left - self.edgeInsets.right
        let tileWidth = max((innerWidth - CGFloat(self.columns - 1) * self.contentStack.spacing) / CGFloat(self.columns), self.iconSize)

        var rowStack: NSStackView? = nil
        apps.enumerated().forEach { idx, app in
            if idx % self.columns == 0 {
                rowStack = NSStackView()
                rowStack?.orientation = .horizontal
                rowStack?.distribution = .fillEqually
                rowStack?.alignment = .top
                rowStack?.spacing = self.contentStack.spacing
                self.contentStack.addArrangedSubview(rowStack!)
            }
            rowStack?.addArrangedSubview(self.appTile(app, width: tileWidth))
        }

        let rows = (apps.count + self.columns - 1) / self.columns
        let h = self.edgeInsets.top + 16 + self.spacing + CGFloat(rows) * (self.iconSize + 26 + self.contentStack.spacing) + self.edgeInsets.bottom
        self.heightConstraint?.constant = CGFloat(h)
        self.setFrameSize(NSSize(width: self.frame.width, height: CGFloat(h)))
        self.onResize?()
    }

    private func showEmpty() {
        let label = NSTextField(labelWithString: localizedString("Add apps in settings"))
        label.textColor = .secondaryLabelColor
        label.font = NSFont.systemFont(ofSize: 11)
        label.alignment = .center
        self.contentStack.addArrangedSubview(label)
        self.heightConstraint?.constant = 60
        self.setFrameSize(NSSize(width: self.frame.width, height: 60))
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

    private func appTile(_ app: (url: URL, name: String, icon: NSImage), width: CGFloat) -> NSView {
        let view = HoverTile()
        view.orientation = .vertical
        view.alignment = .centerX
        view.spacing = 2
        view.widthAnchor.constraint(equalToConstant: width).isActive = true

        let imageView = NSImageView(image: app.icon)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.widthAnchor.constraint(equalToConstant: self.iconSize).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: self.iconSize).isActive = true

        let label = NSTextField(labelWithString: app.name)
        label.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        view.addArrangedSubview(imageView)
        view.addArrangedSubview(label)

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
