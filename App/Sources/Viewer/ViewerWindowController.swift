import AppKit
import BifoldCore
import BifoldWorkspace
import HexFiend
import UniformTypeIdentifiers

/// Podgląd pliku (F3): tekst w wybranym kodowaniu, hex (HexFiend), obrazy.
/// Esc lub F3 zamyka okno, 1/2/3 przełącza tryb.
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    enum Mode: Int { case text, hex, image }

    private let item: FileItem
    var onClose: (() -> Void)?
    private let modeControl = NSSegmentedControl()
    private let encodingPopup = NSPopUpButton()
    private let wrapCheckbox = NSButton(checkboxWithTitle: L10n.tr("Zawijaj wiersze"), target: nil, action: nil)
    private let infoLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private var textScroll: NSScrollView?
    private var encoding: TextEncoding = .utf8
    private var mode: Mode = .text
    private var sample = Data()
    /// Tekst czytamy do tego limitu (większe pliki — tylko początek; całość w trybie hex).
    private let textLimit: Int64 = 32 * 1024 * 1024

    init(item: FileItem) {
        self.item = item
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = item.name
        window.setFrameAutosaveName("ViewerWindow")
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        build()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isImage: Bool {
        UTType(filenameExtension: item.fileExtension.lowercased())?.conforms(to: .image) ?? false
    }

    private func build() {
        guard let content = window?.contentView else { return }
        modeControl.segmentCount = 3
        modeControl.setLabel(L10n.tr("Tekst"), forSegment: 0)
        modeControl.setLabel("Hex", forSegment: 1)
        modeControl.setLabel(L10n.tr("Obraz"), forSegment: 2)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        for e in TextEncoding.allCases { encodingPopup.addItem(withTitle: e.displayName) }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged)
        wrapCheckbox.target = self
        wrapCheckbox.action = #selector(wrapChanged)
        wrapCheckbox.state = .on
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: 11)
        let toolbar = NSStackView(views: [modeControl, encodingPopup, wrapCheckbox, NSView(), infoLabel])
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func load() {
        let size = max(0, item.size)
        infoLabel.stringValue = "\(Format.bytes(size)) · \(item.path.path)"
        let fs = LocalFS()
        sample = (try? fs.readSync(item.path, range: 0..<min(size, textLimit))) ?? Data()
        encoding = TextDecoding.detect(sample)
        encodingPopup.selectItem(at: TextEncoding.allCases.firstIndex(of: encoding) ?? 0)
        if isImage {
            show(.image)
        } else if TextDecoding.looksBinary(sample) {
            show(.hex)
        } else {
            show(.text)
        }
    }

    private func show(_ newMode: Mode) {
        mode = newMode
        modeControl.selectedSegment = newMode.rawValue
        encodingPopup.isHidden = newMode != .text
        wrapCheckbox.isHidden = newMode != .text
        container.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch newMode {
        case .text: view = makeTextView()
        case .hex: view = makeHexView()
        case .image: view = makeImageView()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window?.makeFirstResponder(view is NSScrollView ? (view as! NSScrollView).documentView : view)
    }

    private func makeTextView() -> NSView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        var text = TextDecoding.decode(sample, as: encoding)
        if item.size > textLimit { text += "\n\n" + L10n.tr("[… pokazano pierwsze \(Format.bytes(textLimit)) — całość w trybie Hex]") }
        textView.string = text
        textScroll = scroll
        applyWrap(textView, scroll)
        return scroll
    }

    private func applyWrap(_ textView: NSTextView, _ scroll: NSScrollView) {
        let wrap = wrapCheckbox.state == .on
        scroll.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(width: wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }

    private func makeHexView() -> NSView {
        let hex = HFTextView(frame: .zero)
        if let reference = try? HFFileReference(path: item.path.path) {
            let array = HFBTreeByteArray()
            array.insertByteSlice(HFFileByteSlice(file: reference), in: HFRangeMake(0, 0))
            hex.controller.byteArray = array
        } else {
            hex.data = sample
        }
        hex.controller.editable = false
        return hex
    }

    private func makeImageView() -> NSView {
        let scroll = NSScrollView()
        let imageView = NSImageView()
        imageView.image = NSImage(contentsOf: item.path.url!)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.animates = true
        scroll.documentView = imageView
        scroll.allowsMagnification = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        imageView.frame = NSRect(origin: .zero, size: imageView.image?.size ?? .zero)
        DispatchQueue.main.async {
            let size = imageView.image?.size ?? .zero
            let visible = scroll.contentSize
            if size.width > 0, size.height > 0 {
                scroll.magnification = min(1, min(visible.width / size.width, visible.height / size.height))
            }
        }
        return scroll
    }

    @objc private func modeChanged() {
        show(Mode(rawValue: modeControl.selectedSegment) ?? .text)
    }

    @objc private func encodingChanged() {
        encoding = TextEncoding.allCases[encodingPopup.indexOfSelectedItem]
        if mode == .text { show(.text) }
    }

    @objc private func wrapChanged() {
        if let scroll = textScroll, let tv = scroll.documentView as? NSTextView { applyWrap(tv, scroll) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event) else { return false }
        // Pole wyszukiwania (Cmd+F) przyjmuje zwykłe znaki.
        if let tv = window?.firstResponder as? NSTextView, tv.isEditable, chord.key != "escape" { return false }
        switch (chord.key, chord.modifiers) {
        case ("escape", []), ("f3", []):
            close()
            return true
        case ("1", []): show(.text); return true
        case ("2", []): show(.hex); return true
        case ("3", []): show(.image); return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Okno przekazujące klawisze do kontrolera przed widokami.
final class ViewerWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}
