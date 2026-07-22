//
//  Settings.swift
//  Quota
//

import Cocoa
import Kit

internal class Settings: NSStackView, Settings_v, NSTextFieldDelegate {
    private let title: String
    private var kimiApiKey: String = ""
    private var enableCodexState: Bool = true
    private var updateIntervalValue: Int = 600

    public var callback: (() -> Void) = {}
    public var callbackWhenUpdateNumberOfProcesses: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in}
    public var setTopInterval: ((_ value: Int) -> Void) = {_ in}

    public init(_ module: ModuleType) {
        self.title = module.stringValue

        self.kimiApiKey = Store.shared.string(key: "\(self.title)_kimiApiKey", defaultValue: "")
        self.enableCodexState = Store.shared.bool(key: "\(self.title)_enableCodex", defaultValue: true)
        self.updateIntervalValue = Store.shared.int(key: "\(self.title)_updateInterval", defaultValue: 600)

        super.init(frame: NSRect.zero)

        self.orientation = .vertical
        self.spacing = Constants.Settings.margin
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func load(widgets: [widget_t]) {
        self.subviews.forEach { $0.removeFromSuperview() }

        self.addArrangedSubview(PreferencesSection([
            PreferencesRow("Kimi API Key", component: self.inputField(
                id: "\(self.title)_kimiApiKey",
                value: self.kimiApiKey,
                placeholder: "粘贴 Kimi API Key（Bearer，用于 api.kimi.com/coding）"
            ))
        ]))

        self.addArrangedSubview(PreferencesSection([
            PreferencesRow("启用 Codex 额度", component: switchView(
                action: #selector(self.toggleCodex),
                state: self.enableCodexState
            )),
            PreferencesRow("刷新间隔", component: selectView(
                action: #selector(self.changeUpdateInterval),
                items: [
                    KeyValue_t(key: "300", value: "5 分钟"),
                    KeyValue_t(key: "600", value: "10 分钟"),
                    KeyValue_t(key: "1800", value: "30 分钟"),
                    KeyValue_t(key: "3600", value: "1 小时")
                ],
                selected: "\(self.updateIntervalValue)"
            ))
        ]))

        self.addArrangedSubview(PreferencesSection([
            PreferencesRow("Codex 凭据来源",
                component: label("自动读取 ~/.codex/auth.json"))
        ]))
    }

    // MARK: controls

    private func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        f.textColor = .secondaryLabelColor
        return f
    }

    private func inputField(id: String, value: String, placeholder: String) -> NSView {
        let field: NSTextField = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        field.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        field.textColor = .textColor
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.focusRingType = .none
        field.stringValue = value
        field.delegate = self
        field.placeholderString = placeholder
        return field
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let id = field.identifier?.rawValue else { return }
        if id == "\(self.title)_kimiApiKey" {
            self.kimiApiKey = field.stringValue.trimmingCharacters(in: .whitespaces)
            Store.shared.set(key: "\(self.title)_kimiApiKey", value: self.kimiApiKey)
            self.callback()
        }
    }

    @objc private func toggleCodex(_ sender: NSSwitch) {
        self.enableCodexState = sender.state == .on
        Store.shared.set(key: "\(self.title)_enableCodex", value: self.enableCodexState)
        self.callback()
    }

    @objc private func changeUpdateInterval(_ sender: NSMenuItem) {
        guard let value = Int(sender.title) else { return }
        self.updateIntervalValue = value
        Store.shared.set(key: "\(self.title)_updateInterval", value: value)
        self.setInterval(value)
    }
}
