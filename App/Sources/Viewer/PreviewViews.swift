import AppKit
import AVFoundation
import AVKit
import BifoldCore
import PDFKit
import Quartz

/// Widoki trybu „Podgląd” przeglądarki F3: obraz, film/dźwięk (AVKit), PDF (PDFKit) i dokumenty
/// (Quick Look). Pod widokiem pasek z podstawowymi informacjami o pliku.
enum PreviewViews {
    /// Widok z paskiem informacji pod spodem; `info` można uzupełnić później (dane czytane w tle).
    final class Container: NSView {
        let info = NSTextField(labelWithString: "")

        init(content: NSView, info text: String = "") {
            super.init(frame: .zero)
            info.stringValue = text
            info.font = .systemFont(ofSize: 11)
            info.textColor = .secondaryLabelColor
            info.lineBreakMode = .byTruncatingTail
            info.isSelectable = true
            info.toolTip = text
            let bar = NSView()
            for v in [content, bar, info] { v.translatesAutoresizingMaskIntoConstraints = false }
            addSubview(content)
            addSubview(bar)
            bar.addSubview(info)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bar.topAnchor),
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: 24),
                info.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
                info.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -10),
                info.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func setInfo(_ text: String) {
            info.stringValue = text
            info.toolTip = text
        }
    }

    // MARK: Obraz

    /// Obraz dopasowany do okna (powiększanie gestem / Cmd+scroll), animowany GIF się odtwarza.
    static func image(_ image: NSImage?, info: ImageInfo?) -> NSView {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return Container(content: message(L10n.tr("Nie udało się odczytać obrazu.")), info: info?.summary ?? "")
        }
        let scroll = FittingScrollView()
        scroll.contentView = CenteringClipView()
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        // Rozmiar w pikselach (obraz 144 dpi nie jest dwa razy mniejszy niż w innych przeglądarkach).
        let size = info.map { NSSize(width: $0.width, height: $0.height) } ?? image.size
        imageView.frame = NSRect(origin: .zero, size: size)
        scroll.documentView = imageView
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 16
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        return Container(content: scroll, info: info?.summary ?? "")
    }

    /// Przy pierwszym ułożeniu (znany rozmiar okna) dopasowuje obraz: duży — zmniejszony do okna,
    /// mały — w rzeczywistym rozmiarze. Wcześniej rozmiar widoku jest zerowy.
    final class FittingScrollView: NSScrollView {
        private var fitted = false

        override func layout() {
            super.layout()
            guard !fitted, let size = documentView?.frame.size, size.width > 0, size.height > 0 else { return }
            let visible = contentSize
            guard visible.width > 0, visible.height > 0 else { return }
            fitted = true
            magnification = max(minMagnification, min(1, min(visible.width / size.width, visible.height / size.height)))
        }
    }

    /// Obraz mniejszy od okna wyśrodkowany (domyślnie przykleja się do lewego dolnego rogu).
    final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            guard let doc = documentView?.frame else { return rect }
            if rect.width > doc.width { rect.origin.x = (doc.width - rect.width) / 2 }
            if rect.height > doc.height { rect.origin.y = (doc.height - rect.height) / 2 }
            return rect
        }
    }

    // MARK: Film i dźwięk

    /// Odtwarzacz AVKit (Spacja — odtwarzanie/pauza, strzałki — przewijanie). Odtwarzanie nie startuje samo.
    static func media(_ url: URL, isAudio: Bool) -> (view: NSView, player: AVPlayer) {
        let player = AVPlayer(url: url)
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = !isAudio
        playerView.allowsPictureInPicturePlayback = false
        let container = Container(content: playerView, info: L10n.tr("Wczytywanie informacji…"))
        Task { [weak container] in
            let text = await mediaSummary(AVURLAsset(url: url))
            container?.setInfo(text)
        }
        return (container, player)
    }

    /// „01:23:45 · 1920 × 1080 · H.264 · 29,97 kl./s · 8,2 Mb/s · AAC 48 kHz stereo”.
    static func mediaSummary(_ asset: AVURLAsset) async -> String {
        guard let (duration, tracks) = try? await asset.load(.duration, .tracks) else {
            return L10n.tr("Nie udało się odczytać pliku multimedialnego (format nieobsługiwany przez macOS).")
        }
        var parts: [String] = []
        if duration.isNumeric { parts.append(Self.duration(duration.seconds)) }
        for track in tracks {
            let type = track.mediaType
            guard let (formats, rate) = try? await track.load(.formatDescriptions, .estimatedDataRate) else { continue }
            let codec = formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) }
            if type == .video {
                if let (size, transform, fps) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) {
                    let r = size.applying(transform)
                    parts.append("\(Int(abs(r.width))) × \(Int(abs(r.height)))")
                    if let codec { parts.append(codec) }
                    if fps > 0 { parts.append(L10n.tr("\(fps.formatted(.number.precision(.fractionLength(0...2)))) kl./s")) }
                }
                if rate > 0 { parts.append(bitrate(rate)) }
            } else if type == .audio {
                var audio = [codec].compactMap { $0 }
                if let desc = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    if asbd.mSampleRate > 0 { audio.append("\((asbd.mSampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz") }
                    switch asbd.mChannelsPerFrame {
                    case 1: audio.append(L10n.tr("mono"))
                    case 2: audio.append(L10n.tr("stereo"))
                    case 0: break
                    case let n: audio.append(L10n.tr("kanały: \(Int(n))"))
                    }
                }
                if rate > 0, !tracks.contains(where: { $0.mediaType == .video }) { audio.append(bitrate(rate)) }
                if !audio.isEmpty { parts.append(audio.joined(separator: " ")) }
            }
        }
        if let metadata = try? await asset.load(.commonMetadata) {
            for key in [AVMetadataKey.commonKeyArtist, .commonKeyTitle, .commonKeyAlbumName] {
                if let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first,
                   let value = try? await item.load(.stringValue), !value.isEmpty {
                    parts.append(value)
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bitrate(_ bitsPerSecond: Float) -> String {
        bitsPerSecond >= 1_000_000
            ? "\((Double(bitsPerSecond) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mb/s"
            : "\(Int(bitsPerSecond / 1000)) kb/s"
    }

    /// Nazwa kodeka z kodu FourCC (`avc1` → H.264).
    static func codecName(_ code: FourCharCode) -> String {
        let known: [FourCharCode: String] = [
            kCMVideoCodecType_H264: "H.264", kCMVideoCodecType_HEVC: "HEVC", kCMVideoCodecType_HEVCWithAlpha: "HEVC",
            kCMVideoCodecType_AppleProRes422: "ProRes 422", kCMVideoCodecType_AppleProRes4444: "ProRes 4444",
            kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ", kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT",
            kCMVideoCodecType_MPEG4Video: "MPEG-4", kCMVideoCodecType_JPEG: "Motion JPEG",
            kAudioFormatMPEG4AAC: "AAC", kAudioFormatMPEGLayer3: "MP3", kAudioFormatAppleLossless: "ALAC",
            kAudioFormatLinearPCM: "PCM", kAudioFormatFLAC: "FLAC", kAudioFormatOpus: "Opus", kAudioFormatAC3: "AC-3",
            kAudioFormatEnhancedAC3: "E-AC-3",
        ]
        if let name = known[code] { return name }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: PDF

    static func pdf(_ url: URL) -> NSView {
        guard let document = PDFDocument(url: url) else {
            return Container(content: message(L10n.tr("Nie udało się otworzyć dokumentu PDF.")))
        }
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        let attributes = document.documentAttributes ?? [:]
        var parts = [L10n.tr("stron: \(document.pageCount)")]
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            parts.append("\(Int((box.width / 72 * 25.4).rounded())) × \(Int((box.height / 72 * 25.4).rounded())) mm")
        }
        for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .creatorAttribute] {
            if let value = attributes[key] as? String, !value.isEmpty { parts.append(value) }
        }
        if document.isEncrypted { parts.append(L10n.tr("zaszyfrowany")) }
        return Container(content: view, info: parts.joined(separator: " · "))
    }

    // MARK: Quick Look

    /// Dokumenty Office, iWork, RTF, czcionki, modele 3D — przez systemowy Quick Look.
    static func quickLook(_ url: URL) -> (view: NSView, preview: QLPreviewView?) {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            return (Container(content: message(L10n.tr("Podgląd niedostępny."))), nil)
        }
        preview.autostarts = false
        preview.shouldCloseWithWindow = true
        preview.previewItem = url as NSURL
        return (Container(content: preview, info: L10n.tr("Podgląd systemowy (Quick Look)")), preview)
    }

    // MARK: Pomocnicze

    static func message(_ text: String) -> NSView {
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
}
