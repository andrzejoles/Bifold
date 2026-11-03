import AppKit
import AVFoundation
import BifoldCore
import BifoldWorkspace
import HexFiend
import Quartz

/// Przeglądarka pliku (F3). Rodzaj pliku rozpoznawany po zawartości i rozszerzeniu (`ViewerDetection`):
/// obraz z informacjami, film i dźwięk z odtwarzaczem (AVKit), PDF (PDFKit), dokumenty (Quick Look),
/// tekst z kolorowaniem składni (Highlightr), reszta w hex (HexFiend).
/// Esc lub F3 zamyka okno, 1/2/3 przełącza tryb (tekst / hex / podgląd).
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    enum Mode: Int { case text, hex, preview }

    private let item: FileItem
    var onClose: (() -> Void)?
    private let modeControl = NSSegmentedControl()
    private let encodingPopup = NSPopUpButton()
    private let wrapCheckbox = NSButton(checkboxWithTitle: L10n.tr("Zawijaj wiersze"), target: nil, action: nil)
    private let syntaxCheckbox = NSButton(checkboxWithTitle: L10n.tr("Kolorowanie składni"), target: nil, action: nil)
    /// JSON i XML: wcięcia (`CodeFormatter`); oryginał po wyłączeniu.
    private let formatCheckbox = NSButton(checkboxWithTitle: L10n.tr("Formatuj"), target: nil, action: nil)
    /// Rozmiar i ścieżka — tekst paska narzędzi bez komunikatu o formatowaniu.
    private var baseInfo = ""
    private let infoLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private var textScroll: NSScrollView?
    private var encoding: TextEncoding = .utf8
    private var mode: Mode = .text
    private var sample = Data()
    /// Próbka jeszcze się wczytuje (plik „tylko w chmurze” albo na SMB może czytać się długo).
    private var loading = true
    private var content: ViewerContent = .binary
    private var image: NSImage?
    private var imageInfo: ImageInfo?
    private var imageLoaded = false
    private var imageLoading = false
    /// Odtwarzacz i podgląd Quick Look — zatrzymywane przy zmianie trybu i zamknięciu okna.
    private var player: AVPlayer?
    private var quickLook: QLPreviewView?
    /// Numer bieżącego widoku tekstu — wynik kolorowania dla starszego widoku jest pomijany.
    private var textGeneration = 0
    private var closed = false
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

    private func build() {
        guard let content = window?.contentView else { return }
        modeControl.segmentCount = 3
        modeControl.setLabel(L10n.tr("Tekst"), forSegment: 0)
        modeControl.setLabel("Hex", forSegment: 1)
        modeControl.setLabel(L10n.tr("Podgląd"), forSegment: 2)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        for e in TextEncoding.allCases { encodingPopup.addItem(withTitle: e.displayName) }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged)
        wrapCheckbox.target = self
        wrapCheckbox.action = #selector(wrapChanged)
        wrapCheckbox.state = .on
        syntaxCheckbox.target = self
        syntaxCheckbox.action = #selector(syntaxChanged)
        syntaxCheckbox.state = .on
        formatCheckbox.target = self
        formatCheckbox.action = #selector(syntaxChanged)
        formatCheckbox.state = .off
        formatCheckbox.toolTip = L10n.tr("Wcięcia i podział na wiersze (JSON, XML); plik się nie zmienia")
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: 11)
        let toolbar = NSStackView(views: [modeControl, encodingPopup, wrapCheckbox, syntaxCheckbox, formatCheckbox, NSView(), infoLabel])
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

    /// Próbka i obraz są czytane poza wątkiem głównym (plik iCloud „tylko w chmurze” czy na SMB
    /// zamrażałby aplikację); okno od razu pokazuje wskaźnik. Wynik po zamknięciu okna jest pomijany.
    private func load() {
        let size = max(0, item.size)
        baseInfo = "\(Format.bytes(size)) · \(item.path.path)"
        infoLabel.stringValue = baseInfo
        modeControl.isEnabled = false
        encodingPopup.isHidden = true
        wrapCheckbox.isHidden = true
        syntaxCheckbox.isHidden = true
        formatCheckbox.isHidden = true
        install(loadingView())
        let path = item.path, limit = min(size, textLimit)
        Task { [weak self] in
            let name = path.name
            let result = try? await runBlocking(qos: .userInitiated) { () -> (Data, TextEncoding, ViewerContent) in
                let sample = try LocalFS().readSync(path, range: 0..<limit)
                return (sample, TextDecoding.detect(sample), ViewerDetection.detect(name: name, sample: sample))
            }
            guard let self, !self.closed else { return }
            let (sample, encoding, content) = result ?? (Data(), .utf8, .text(language: nil))
            self.sample = sample
            self.encoding = encoding
            self.content = content
            self.loading = false
            self.modeControl.isEnabled = true
            self.modeControl.setEnabled(content.hasPreview, forSegment: Mode.preview.rawValue)
            self.encodingPopup.selectItem(at: TextEncoding.allCases.firstIndex(of: encoding) ?? 0)
            switch content {
            case .text: self.show(content.hasPreview ? .preview : .text)
            case .binary: self.show(.hex)
            default: self.show(.preview)
            }
        }
    }

    private var language: String? {
        if case .text(let language) = content { return language }
        return nil
    }

    private func show(_ newMode: Mode) {
        guard !loading, !closed else { return }
        if newMode == .preview, !content.hasPreview { return }
        stopMedia()
        mode = newMode
        modeControl.selectedSegment = newMode.rawValue
        encodingPopup.isHidden = newMode != .text
        wrapCheckbox.isHidden = newMode != .text
        syntaxCheckbox.isHidden = newMode != .text || language == nil
        formatCheckbox.isHidden = newMode != .text || !CodeFormatter.supports(language: language)
        infoLabel.stringValue = baseInfo
        let view: NSView
        switch newMode {
        case .text: view = makeTextView()
        case .hex: view = makeHexView()
        case .preview: view = makePreview()
        }
        install(view)
        window?.makeFirstResponder(Self.focusTarget(in: view))
    }

    /// Widok, który dostaje klawiaturę (tekst, hex, odtwarzacz — Spacja odtwarza).
    private static func focusTarget(in view: NSView) -> NSView {
        if let scroll = view as? NSScrollView, let doc = scroll.documentView { return doc }
        if let container = view as? PreviewViews.Container, let content = container.subviews.first {
            return focusTarget(in: content)
        }
        return view
    }

    private func stopMedia() {
        player?.pause()
        player = nil
        quickLook?.close()
        quickLook = nil
    }

    private func install(_ view: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func loadingView() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: L10n.tr("Wczytywanie pliku…"))
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
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
        textGeneration += 1
        let generation = textGeneration
        if !formatCheckbox.isHidden, formatCheckbox.state == .on, item.size <= textLimit {
            format(textView, text: text, generation: generation)
        } else if let language, syntaxCheckbox.state == .on {
            highlight(textView, text: text, language: language, generation: generation)
        }
        return scroll
    }

    /// „Formatuj” w tle (duży JSON/XML), potem kolorowanie sformatowanego tekstu. Niepoprawny dokument
    /// zostaje bez zmian, a powód widać w pasku narzędzi.
    private func format(_ textView: NSTextView, text: String, generation: Int) {
        let language = language
        Task { [weak self, weak textView] in
            let result = (try? await runBlocking(qos: .userInitiated) { CodeFormatter.format(text, language: language) })
                ?? .failure(.invalid(""))
            guard let self, let textView, !self.closed, generation == self.textGeneration else { return }
            var shown = text
            switch result {
            case .success(let formatted):
                shown = formatted
                textView.string = formatted
                textView.scroll(.zero)
            case .failure(.tooLarge):
                self.infoLabel.stringValue = L10n.tr("Plik za duży do formatowania") + " · " + self.baseInfo
            case .failure(.invalid(let reason)):
                let detail = reason.isEmpty ? "" : " (\(reason))"
                self.infoLabel.stringValue = L10n.tr("Niepoprawny dokument — bez formatowania") + detail + " · " + self.baseInfo
            }
            self.infoLabel.toolTip = self.infoLabel.stringValue
            if let language, self.syntaxCheckbox.state == .on {
                self.highlight(textView, text: shown, language: language, generation: generation)
            }
        }
    }

    /// Kolorowanie w tle — tekst jest od razu widoczny bez kolorów, kolory dochodzą po chwili.
    private func highlight(_ textView: NSTextView, text: String, language: String, generation: Int) {
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let font = textView.font ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let fontName = font.fontName, fontSize = font.pointSize
        Task { [weak self, weak textView] in
            guard let result = await SyntaxHighlighter.shared.highlight(text, language: language, dark: dark, fontName: fontName, fontSize: fontSize),
                  let self, let textView, !self.closed, generation == self.textGeneration else { return }
            let selection = textView.selectedRanges
            textView.textStorage?.setAttributedString(result.text)
            textView.selectedRanges = selection
            if let background = result.background { textView.backgroundColor = background }
        }
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
        // Tylko plik lokalny — ścieżka z serwera czy telefonu wskazałaby inny plik o tej samej ścieżce na dysku.
        if item.path.isLocal, let reference = try? HFFileReference(path: item.path.path) {
            let array = HFBTreeByteArray()
            array.insertByteSlice(HFFileByteSlice(file: reference), in: HFRangeMake(0, 0))
            hex.controller.byteArray = array
        } else {
            hex.data = sample
        }
        hex.controller.editable = false
        return hex
    }

    private func makePreview() -> NSView {
        // Podgląd czyta tylko pliki lokalne (z serwera, archiwum i telefonu komenda pobiera kopię).
        guard let url = item.path.url else { return messageView(L10n.tr("Podgląd jest dostępny tylko dla plików na dysku.")) }
        switch content {
        case .image:
            guard imageLoaded else {
                loadImage(url)
                return loadingView()
            }
            return PreviewViews.image(image, info: imageInfo)
        case .video, .audio:
            let (view, player) = PreviewViews.media(url, isAudio: content == .audio)
            self.player = player
            return view
        case .pdf:
            return PreviewViews.pdf(url)
        case .document:
            let (view, preview) = PreviewViews.quickLook(url)
            quickLook = preview
            return view
        case .text:
            // Markdown wyrenderowany; surowy plik — tryb „Tekst” (1).
            var text = TextDecoding.decode(sample, as: encoding)
            if item.size > textLimit { text += "\n\n" + L10n.tr("[… pokazano pierwsze \(Format.bytes(textLimit)) — całość w trybie Hex]") }
            return PreviewViews.markdown(text, title: item.name, directory: url.deletingLastPathComponent())
        case .binary:
            return messageView(L10n.tr("Brak podglądu dla tego rodzaju pliku."))
        }
    }

    /// Obraz i jego właściwości czytane w tle (NSImage(contentsOf:) czytałby cały plik na wątku głównym).
    private func loadImage(_ url: URL) {
        guard !imageLoading else { return }
        imageLoading = true
        Task { [weak self] in
            let loaded = try? await runBlocking(qos: .userInitiated) { () -> (Data, ImageInfo?) in
                (try Data(contentsOf: url), ImageInfo.read(url))
            }
            guard let self, !self.closed else { return }
            self.imageLoading = false
            self.imageLoaded = true
            self.image = loaded.flatMap { NSImage(data: $0.0) }
            self.imageInfo = loaded?.1
            if self.mode == .preview { self.show(.preview) }
        }
    }

    private func messageView(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        return container
    }

    @objc private func modeChanged() {
        show(Mode(rawValue: modeControl.selectedSegment) ?? .text)
    }

    @objc private func encodingChanged() {
        encoding = TextEncoding.allCases[encodingPopup.indexOfSelectedItem]
        if mode == .text { show(.text) }
    }

    @objc private func syntaxChanged() {
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
        case ("escape", []) where mode == .text && textScroll?.isFindBarVisible == true:
            // Esc najpierw chowa pasek wyszukiwania (jak w innych aplikacjach), dopiero potem zamyka okno.
            if let textView = textScroll?.documentView as? NSTextView {
                let action = NSMenuItem()
                action.tag = NSTextFinder.Action.hideFindInterface.rawValue
                textView.performTextFinderAction(action)
                window?.makeFirstResponder(textView)
            }
            textScroll?.isFindBarVisible = false
            return true
        case ("escape", []), ("f3", []):
            close()
            return true
        case ("1", []): show(.text); return true
        case ("2", []): show(.hex); return true
        case ("3", []): show(.preview); return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        stopMedia()
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
