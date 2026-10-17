import AppKit
import BifoldCore
import BifoldWorkspace
import UniformTypeIdentifiers

enum Theme {
    static func apply(_ theme: AppTheme) {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Kolor zaznaczonych (oznaczonych) plików — jak czerwień w Total Commanderze.
    static let markedText = NSColor.systemRed
    static let markedBackground = NSColor.systemRed.withAlphaComponent(0.10)

    static func color(_ c: HexColor) -> NSColor {
        NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    static func font(size: CGFloat, style: FileStyle?, marked: Bool) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: (style?.bold ?? false) || marked ? .semibold : .regular)
        if style?.italic == true {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func attributes(size: CGFloat, style: FileStyle?, marked: Bool, secondary: Bool = false) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: secondary ? NSFont.monospacedDigitSystemFont(ofSize: size - 1, weight: .regular) : font(size: size, style: style, marked: marked)]
        if marked {
            attrs[.foregroundColor] = markedText
        } else if let c = style?.textColor {
            attrs[.foregroundColor] = color(c)
        } else {
            attrs[.foregroundColor] = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor
        }
        if style?.strikethrough == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }
}

/// Ikony plików: pobieranie per plik jest wolne przy 100 000 wierszy, więc ikony są
/// buforowane według typu (rozszerzenia); własne ikony tylko dla aplikacji i woluminów.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var byExtension: [String: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    private lazy var folder: NSImage = NSWorkspace.shared.icon(for: .folder)
    private lazy var parent: NSImage = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "..") ?? folder
    private lazy var generic: NSImage = NSWorkspace.shared.icon(for: .data)
    private lazy var symlink: NSImage = NSWorkspace.shared.icon(for: .aliasFile)

    func icon(for item: FileItem) -> NSImage {
        if item.isParentLink { return parent }
        if item.isDirectory {
            let ext = item.name.fileExtension.lowercased()
            if ext == "app" || ext == "bundle" || ext == "framework" || ext == "pkg" {
                if let cached = byPath[item.path.path] { return cached }
                let image = NSWorkspace.shared.icon(forFile: item.path.path)
                byPath[item.path.path] = image
                return image
            }
            return folder
        }
        if item.kind == .symlink { return item.isNavigable ? folder : symlink }
        let ext = item.fileExtension.lowercased()
        if ext.isEmpty { return item.isExecutable ? NSWorkspace.shared.icon(for: .unixExecutable) : generic }
        if let cached = byExtension[ext] { return cached }
        let image = UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? generic
        byExtension[ext] = image
        return image
    }
}

/// Wspólne formatowanie liczb i dat w listach (formatery są kosztowne w tworzeniu).
@MainActor
enum Formatters {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pl_PL")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func size(_ item: FileItem, directorySize: DirectorySize?) -> String {
        if item.isParentLink { return "" }
        if item.isNavigable {
            if let d = directorySize { return grouped(d.bytes) }
            return L10n.tr("<KAT>")
        }
        return grouped(item.size)
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pl_PL")
        return f
    }()

    static func grouped(_ n: Int64) -> String {
        groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func permissions(_ item: FileItem) -> String {
        let p = item.permissions
        let chars: [Character] = ["r", "w", "x"]
        var s = item.isNavigable ? "d" : (item.kind == .symlink ? "l" : "-")
        for shift in [6, 3, 0] {
            for (i, c) in chars.enumerated() {
                s.append(p >> UInt16(shift + 2 - i) & 1 == 1 ? c : "-")
            }
        }
        return s
    }
}
