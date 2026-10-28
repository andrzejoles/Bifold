import AppKit
import BifoldCore
import BifoldWorkspace

/// Linia poleceń pod panelami: polecenie wykonywane w bieżącym katalogu aktywnego panelu,
/// w powłoce użytkownika, z wynikiem w wbudowanym terminalu.
final class CommandLineBar: NSView, NSTextFieldDelegate {
    private let workspace: Workspace
    private let prompt = NSTextField(labelWithString: "")
    let field = NSTextField()
    private var history: [String] = []
    private var historyIndex = 0

    var directory: VFSPath = .root {
        didSet { prompt.stringValue = (directory.path as NSString).abbreviatingWithTildeInPath + " $" }
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        prompt.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        prompt.textColor = .secondaryLabelColor
        prompt.lineBreakMode = .byTruncatingHead
        prompt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        prompt.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = L10n.tr("Polecenie powłoki w bieżącym katalogu (Enter — wykonaj w terminalu)")
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.target = self
        field.action = #selector(submit)
        let stack = NSStackView(views: [prompt, field])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(field) }

    @objc private func submit() {
        let command = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        history.append(command)
        historyIndex = history.count
        field.stringValue = ""
        // „cd katalog” zmienia katalog panelu zamiast terminala (jak w TC) — tylko samo `cd <ścieżka>`;
        // z operatorami powłoki („cd /tmp && make”) całość idzie do terminala.
        if let path = Self.plainCD(command) {
            workspace.perform("panel.navigate", CommandArguments(["path": .string(path)]))
            return
        }
        workspace.perform("tools.runCommand", CommandArguments(["command": .string(Self.localProgram(command, in: directory))]))
    }

    /// „run.sh” → „./run.sh”, gdy pierwsze słowo to plik wykonywalny w bieżącym katalogu (jak w TC),
    /// a nie polecenie z `PATH` — plik w katalogu nie przesłania `ls` czy `make`.
    static func localProgram(_ command: String, in directory: VFSPath,
                             searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String {
        guard directory.isLocal else { return command }
        let name = String(command.prefix { !$0.isWhitespace })
        // Ścieżki, przypisania (`A=1 cmd`), operatory i cudzysłowy zostają dla powłoki.
        let shellCharacters = Set("/=;&|<>()$`\"'\\*?[]{}!#~")
        guard !name.isEmpty, name != ".", name != "..", !name.contains(where: { shellCharacters.contains($0) }) else {
            return command
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let local = (directory.path as NSString).appendingPathComponent(name)
        guard fm.fileExists(atPath: local, isDirectory: &isDirectory), !isDirectory.boolValue,
              fm.isExecutableFile(atPath: local) else { return command }
        // Aplikacja uruchomiona z Findera ma krótki PATH — także typowe katalogi Homebrew.
        let dirs = searchPath.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        if dirs.contains(where: { fm.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent(name)) }) {
            return command
        }
        return "./" + command
    }

    /// Ścieżka z polecenia `cd` bez operatorów i rozwinięć powłoki; `nil` dla innych poleceń.
    /// Ścieżka w pojedynczym cudzysłowie może zawierać spacje.
    static func plainCD(_ command: String) -> String? {
        guard command == "cd" || command.hasPrefix("cd ") else { return nil }
        var arg = command == "cd" ? "~" : String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if arg.isEmpty { arg = "~" }
        if arg.count >= 2, arg.first == "'", arg.last == "'" {
            let inner = String(arg.dropFirst().dropLast())
            return inner.contains("'") ? nil : inner
        }
        // Operatory, przekierowania, podstawienia, rozwinięcia i cudzysłowy — polecenie dla powłoki.
        let shellCharacters = Set(";&|<>()$`\"'\\*?[]{}!#")
        if arg == "-" || arg.contains(where: { shellCharacters.contains($0) || $0.isWhitespace }) { return nil }
        return arg
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            guard !history.isEmpty else { return true }
            historyIndex = max(0, historyIndex - 1)
            field.stringValue = history[historyIndex]
            return true
        case #selector(NSResponder.moveDown(_:)):
            historyIndex = min(history.count, historyIndex + 1)
            field.stringValue = historyIndex < history.count ? history[historyIndex] : ""
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = ""
            (window?.windowController as? MainWindowController)?.focusActivePanel()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab wraca do panelu, ale nie kasuje wpisanego polecenia.
            (window?.windowController as? MainWindowController)?.focusActivePanel()
            return true
        default:
            return false
        }
    }
}
