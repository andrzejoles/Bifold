import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rodzaj zawartości pliku dla przeglądarki F3 — decyduje o domyślnym widoku.
public enum ViewerContent: Equatable, Sendable {
    case image
    case video
    case audio
    case pdf
    /// Tekst; `language` — nazwa języka highlight.js (kolorowanie składni) albo `nil` (zwykły tekst).
    case text(language: String?)
    /// Dokument, który pokaże Quick Look (Office, iWork, RTF, czcionki, modele 3D…).
    case document
    /// Dane binarne bez podglądu — widok hex.
    case binary

    /// Czy jest widok „Podgląd” (poza tekstem i hex). Markdown — wyrenderowany (tekst = surowy plik).
    public var hasPreview: Bool {
        switch self {
        case .image, .video, .audio, .pdf, .document: true
        case .text(let language): language == "markdown"
        case .binary: false
        }
    }
}

public enum ViewerDetection {
    /// Rozpoznaje rodzaj pliku po zawartości (sygnatury), potem po rozszerzeniu, na końcu po tym, czy
    /// próbka wygląda na tekst. Sygnatura ma pierwszeństwo — obraz bez rozszerzenia albo z błędnym też
    /// jest obrazem, a plik „.png” z tekstem — tekstem.
    public static func detect(name: String, sample: Data) -> ViewerContent {
        if let sniffed = sniff(sample) { return sniffed }
        let ext = name.fileExtension.lowercased()
        let binary = TextDecoding.looksBinary(sample)
        if let type = UTType(filenameExtension: ext) {
            // Obrazy wektorowe i tekstowe (SVG) też jako obraz; inne obrazy tylko, gdy dane nie są tekstem.
            if type.conforms(to: .svg) { return .image }
            if type.conforms(to: .pdf), binary || sample.isEmpty { return .pdf }
            if binary || sample.isEmpty {
                if type.conforms(to: .image) { return .image }
                if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
                if type.conforms(to: .audio) { return .audio }
                if documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
            }
        }
        if binary { return .binary }
        return .text(language: language(forName: name, sample: sample))
    }

    /// Typy, które Quick Look pokazuje lepiej niż hex.
    static let documentTypes: [UTType] = [
        .rtf, .rtfd, .flatRTFD, .presentation, .spreadsheet, .font, .threeDContent, .usdz, .epub,
        UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"), UTType("com.apple.iwork.pages.sffpages"),
        UTType("com.apple.iwork.pages.pages"),
    ].compactMap { $0 }

    /// Sygnatury (magic numbers) najczęstszych formatów — rozpoznanie niezależne od rozszerzenia.
    static func sniff(_ d: Data) -> ViewerContent? {
        let b = [UInt8](d.prefix(16))
        func starts(_ p: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + p.count && Array(b[offset..<offset + p.count]) == p
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .image }          // PNG
        if starts([0xFF, 0xD8, 0xFF]) { return .image }                                        // JPEG
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return .image }      // GIF
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return .image }     // WebP
        if starts(Array("RIFF".utf8)), starts(Array("WAVE".utf8), at: 8) { return .audio }     // WAV
        if starts(Array("RIFF".utf8)), starts(Array("AVI ".utf8), at: 8) { return .video }     // AVI
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .image } // TIFF (też DNG, CR2)
        if starts(Array("BM".utf8)), b.count >= 14 { return .image }                           // BMP
        if starts([0x00, 0x00, 0x01, 0x00]) { return .image }                                  // ICO
        if starts(Array("icns".utf8)) { return .image }
        if starts(Array("%PDF-".utf8)) { return .pdf }
        if starts(Array("fLaC".utf8)) || starts(Array("ID3".utf8)) || starts(Array("OggS".utf8)) { return .audio }
        if starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) || starts([0xFF, 0xF2]) { return .audio } // MP3 bez ID3
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return .video }                                  // Matroska / WebM
        if starts(Array("ftyp".utf8), at: 4), b.count >= 12 {                                  // ISO BMFF
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "heim", "heis", "hevc", "mif1", "msf1", "avif", "avis"].contains(brand) { return .image }
            if ["M4A ", "M4B ", "M4P "].contains(brand) { return .audio }
            return .video                                                                      // mp4, mov (qt  ), m4v, 3gp…
        }
        return nil
    }

    /// Język highlight.js dla nazwy pliku (rozszerzenie, znane nazwy, `#!` w pierwszym wierszu).
    public static func language(forName name: String, sample: Data = Data()) -> String? {
        if let lang = fileNames[name] ?? fileNames[name.lowercased()] { return lang }
        if let lang = extensions[name.fileExtension.lowercased()] { return lang }
        // Skrypt bez rozszerzenia: `#!/usr/bin/env python3`, `#!/bin/bash`.
        let head = String(decoding: sample.prefix(128), as: UTF8.self)
        guard head.hasPrefix("#!"), let line = head.split(separator: "\n").first else { return nil }
        let words = line.dropFirst(2).split(separator: " ").map(String.init)
        guard var program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if program == "env", words.count > 1 { program = words[1] }
        return shebangs.first { program.hasPrefix($0.key) }?.value
    }

    static let fileNames: [String: String] = [
        "Makefile": "makefile", "makefile": "makefile", "GNUmakefile": "makefile", "Dockerfile": "dockerfile",
        "CMakeLists.txt": "cmake", "Podfile": "ruby", "Gemfile": "ruby", "Rakefile": "ruby", "Vagrantfile": "ruby",
        ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "bash", ".zprofile": "bash", ".profile": "bash",
        ".gitconfig": "ini", ".editorconfig": "ini", "Package.swift": "swift",
    ]

    static let shebangs: [String: String] = [
        "python": "python", "bash": "bash", "sh": "bash", "zsh": "bash", "ksh": "bash", "ruby": "ruby",
        "perl": "perl", "node": "javascript", "php": "php", "lua": "lua", "Rscript": "r", "swift": "swift",
        "osascript": "applescript", "tclsh": "tcl", "awk": "awk",
    ]

    static let extensions: [String: String] = [
        "swift": "swift", "m": "objectivec", "mm": "objectivec", "h": "cpp", "hpp": "cpp", "c": "c", "cc": "cpp",
        "cpp": "cpp", "cxx": "cpp", "cs": "csharp", "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala",
        "go": "go", "rs": "rust", "py": "python", "pyw": "python", "rb": "ruby", "pl": "perl", "pm": "perl",
        "php": "php", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "json": "json", "jsonc": "json", "geojson": "json",
        "html": "xml", "htm": "xml", "xhtml": "xml", "xml": "xml", "plist": "xml", "svg": "xml", "xsd": "xml",
        "xsl": "xml", "xslt": "xml", "storyboard": "xml", "xib": "xml", "xcstrings": "json", "css": "css",
        "scss": "scss", "sass": "scss", "less": "less", "md": "markdown", "markdown": "markdown", "yml": "yaml",
        "yaml": "yaml", "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini", "properties": "properties",
        "xcconfig": "ini", "sh": "bash", "bash": "bash", "zsh": "bash", "command": "bash", "fish": "bash",
        "ps1": "powershell", "psm1": "powershell", "bat": "dos", "cmd": "dos", "sql": "sql", "pks": "sql",
        "pkb": "sql", "plsql": "sql", "prc": "sql", "fnc": "sql", "trg": "sql", "lua": "lua", "r": "r",
        "dart": "dart", "groovy": "groovy", "gradle": "gradle", "tex": "latex", "diff": "diff", "patch": "diff",
        "dockerfile": "dockerfile", "mk": "makefile", "cmake": "cmake", "applescript": "applescript",
        "vb": "vbnet", "vbs": "vbscript", "hs": "haskell", "ex": "elixir", "exs": "elixir", "erl": "erlang",
        "clj": "clojure", "lisp": "lisp", "el": "lisp", "ml": "ocaml", "fs": "fsharp", "jl": "julia",
        "nim": "nim", "proto": "protobuf", "graphql": "graphql", "gql": "graphql", "tf": "ini",
        "nginx": "nginx", "awk": "awk", "tcl": "tcl", "asm": "x86asm", "s": "armasm", "csv": "plaintext",
        "log": "accesslog", "http": "http", "ksh": "bash", "vue": "xml", "pas": "delphi", "f90": "fortran",
    ]
}

/// Podstawowe informacje o obrazie (ImageIO, bez dekodowania pikseli).
public struct ImageInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var format: String?
    public var colorModel: String?
    public var bitDepth: Int?
    public var hasAlpha: Bool
    public var dpi: Double?
    public var colorProfile: String?
    public var frames: Int
    public var camera: String?
    public var taken: String?

    public static func read(_ url: URL) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        let camera = [make, model].compactMap { $0 }.filter { !$0.isEmpty }
        let format = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        return ImageInfo(
            width: width, height: height,
            format: format?.preferredFilenameExtension?.uppercased() ?? format?.localizedDescription,
            colorModel: props[kCGImagePropertyColorModel] as? String,
            bitDepth: props[kCGImagePropertyDepth] as? Int,
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            dpi: props[kCGImagePropertyDPIWidth] as? Double,
            colorProfile: props[kCGImagePropertyProfileName] as? String,
            frames: CGImageSourceGetCount(source),
            camera: camera.isEmpty ? nil : (model?.hasPrefix(make ?? "\u{0}") == true ? model : camera.joined(separator: " ")),
            taken: exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
    }

    /// Opis do paska informacji, np. „4032 × 3024 px · JPEG · RGB 8 bit · 72 dpi · Display P3 · Apple iPhone 15”.
    public var summary: String {
        var parts = ["\(width) × \(height) px"]
        if let format { parts.append(format) }
        if let colorModel {
            parts.append([colorModel, bitDepth.map { "\($0) bit" }, hasAlpha ? L10n.tr("z kanałem alfa") : nil].compactMap { $0 }.joined(separator: " "))
        }
        if let dpi, dpi > 0 { parts.append("\(Int(dpi.rounded())) dpi") }
        if let colorProfile { parts.append(colorProfile) }
        if frames > 1 { parts.append(L10n.tr("klatek: \(frames)")) }
        if let camera { parts.append(camera) }
        if let taken { parts.append(taken) }
        return parts.joined(separator: " · ")
    }
}
