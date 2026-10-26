import AppKit
import BifoldCore
import BifoldWorkspace

/// Pasek kart panelu.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String], active: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, title) in titles.enumerated() {
            let button = TabButton(title: title, index: i, active: i == active)
            button.onClick = { [weak self] in self?.onSelect?(i) }
            button.onClose = titles.count > 1 ? { [weak self] in self?.onClose?(i) } : nil
            stack.addArrangedSubview(button)
        }
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.tr("Nowa karta"))!, target: self, action: #selector(newTab))
        plus.bezelStyle = .accessoryBarAction
        plus.isBordered = false
        plus.refusesFirstResponder = true
        plus.toolTip = L10n.tr("Nowa karta")
        stack.addArrangedSubview(plus)
    }

    @objc private func newTab() { onNew?() }
}

private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    private let active: Bool
    private let title: String

    init(title: String, index: Int, active: Bool) {
        self.active = active
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: active ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        toolTip = title
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// Kolor tła z bieżącym wyglądem (także po zmianie motywu).
    override func updateLayer() {
        layer?.backgroundColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
    }

    // Dostępność: karta jest przyciskiem (VoiceOver: „karta …, przycisk”; naciśnięcie wybiera kartę).
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { active ? L10n.tr("aktywna") : nil }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose?() } else { onClick?() }
    }

    override func otherMouseDown(with event: NSEvent) { onClose?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if onClose != nil {
            let close = NSMenuItem(title: L10n.tr("Zamknij kartę"), action: #selector(closeTab), keyEquivalent: "")
            close.target = self
            menu.addItem(close)
        }
        return menu
    }

    @objc private func closeTab() { onClose?() }
}

/// Dysk karty (menu jak w TC), ścieżka bieżącego katalogu (komponenty klikalne) i wolne miejsce.
final class PathBarView: NSView {
    var onNavigate: ((VFSPath) -> Void)?
    /// Kliknięcie przycisku dysku — menu dysków karty.
    var onDrives: (() -> Void)?
    /// Rozłączenie serwera pokazywanego w panelu (przycisk ⏏ widoczny tylko dla połączeń).
    var onDisconnect: (() -> Void)?
    /// Terminal SSH w drugim panelu (przycisk widoczny dla połączeń SFTP/SCP).
    var onTerminal: (() -> Void)?
    var isActive = false { didSet { updateColors() } }
    private let pathControl = NSPathControl()
    /// Ścieżka spoza dysku (`alias:/katalog`, archiwum, telefon) — NSPathControl pokazuje tylko adresy plików.
    private let remoteLabel = NSTextField(labelWithString: "")
    private let disconnectButton = NSButton()
    private let terminalButton = NSButton()
    private let spaceLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let driveButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true

        driveButton.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: L10n.tr("Dysk"))
        driveButton.imagePosition = .imageLeading
        driveButton.bezelStyle = .accessoryBarAction
        driveButton.controlSize = .small
        driveButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        driveButton.target = self
        driveButton.action = #selector(drives)
        driveButton.refusesFirstResponder = true
        driveButton.toolTip = L10n.tr("Dysk karty: wolumin, telefon albo serwer")
        (driveButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        driveButton.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        driveButton.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.refusesFirstResponder = true
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spaceLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        spaceLabel.textColor = .secondaryLabelColor
        spaceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        remoteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        remoteLabel.lineBreakMode = .byTruncatingMiddle
        remoteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteLabel.isHidden = true

        disconnectButton.image = NSImage(systemSymbolName: "eject", accessibilityDescription: L10n.tr("Rozłącz"))
        disconnectButton.isBordered = false
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)
        disconnectButton.refusesFirstResponder = true
        disconnectButton.toolTip = L10n.tr("Rozłącz serwer")
        disconnectButton.isHidden = true

        terminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: L10n.tr("Terminal SSH"))
        terminalButton.isBordered = false
        terminalButton.target = self
        terminalButton.action = #selector(openTerminal)
        terminalButton.refusesFirstResponder = true
        terminalButton.toolTip = L10n.tr("Terminal SSH w drugim panelu")
        terminalButton.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [driveButton, pathControl, remoteLabel, spacer, spinner, spaceLabel, terminalButton, disconnectButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(path: VFSPath, volume: VolumeInfo?, error: String?, loading: Bool, sshTerminal: Bool = false) {
        terminalButton.isHidden = !sshTerminal
        if let url = path.url {
            if pathControl.url != url { pathControl.url = url }
            pathControl.isHidden = false
            remoteLabel.isHidden = true
        } else {
            pathControl.isHidden = true
            remoteLabel.isHidden = false
            remoteLabel.stringValue = path.displayPath
        }
        // Serwer albo telefon — oba da się zamknąć (⏏).
        disconnectButton.isHidden = RemoteFS.alias(of: path) == nil && !path.isDevice
        if let error {
            spaceLabel.stringValue = "⚠︎ " + error
            spaceLabel.textColor = .systemRed
        } else if let v = volume, v.totalCapacity > 0 {
            // Serwery i telefony nie podają pojemności — wtedy bez „0 B wolne”.
            spaceLabel.stringValue = L10n.tr("\(Format.bytes(v.availableCapacity)) wolne")
            spaceLabel.textColor = .secondaryLabelColor
        } else {
            spaceLabel.stringValue = ""
        }
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func updateColors() {
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    /// Kolor tła z bieżącym wyglądem (także po zmianie motywu).
    override func updateLayer() {
        layer?.backgroundColor = isActive ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        if let url = sender.clickedPathItem?.url { onNavigate?(.local(url)) }
    }

    func updateDrive(title: String, image: NSImage?) {
        let label = title + " ▾"
        if driveButton.title != label { driveButton.title = label }
        driveButton.image = image
    }

    /// Menu dysków pod przyciskiem dysku.
    func popUpDriveMenu(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: driveButton.isFlipped ? driveButton.bounds.maxY + 2 : -2), in: driveButton)
    }

    @objc private func drives() { onDrives?() }

    @objc private func disconnect() { onDisconnect?() }

    @objc private func openTerminal() { onTerminal?() }
}
