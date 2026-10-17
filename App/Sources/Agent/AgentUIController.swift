import AppKit
import BifoldAgent
import BifoldBridgeKit
import BifoldCore
import BifoldWorkspace
import SwiftTerm

/// Uruchamianie agentów z aplikacji, panel agenta, okno zatwierdzania i cofanie sesji.
final class AgentUIController: ApprovalPresenter {
    let workspace: Workspace
    let controller: AgentController
    weak var mainWindow: MainWindowController?
    let pane: AgentPane
    private var approvalChain: Task<Void, Never>?
    private var logWindow: AgentLogWindowController?

    init(workspace: Workspace) {
        self.workspace = workspace
        controller = AgentController(workspace: workspace)
        pane = AgentPane(controller: controller)
        controller.approvals = self
        pane.onUndo = { [weak self] id in self?.undoSession(id) }
        pane.onClose = { [weak self] id in self?.endSession(id) }
        pane.onShowLog = { [weak self] in self?.showLog() }
        workspace.register(commands())
        do {
            try controller.start()
        } catch {
            NSLog("Bifold: serwer agentów nie wystartował: \(error)")
        }
    }

    var bridgePath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/bifold-mcp").path
    }

    // MARK: Komendy (tylko dla użytkownika — poziom agenta „Brak”)

    private func commands() -> [Command] {
        var list: [Command] = []
        for (i, kind) in AgentKind.allCases.enumerated() {
            list.append(Command(CommandDescriptor(
                id: CommandID(rawValue: "agent.launch.\(kind.rawValue)"), title: L10n.tr("Uruchom \(kind.displayName)"), category: .agent,
                tc: ["ctrl+alt+\(i + 1)"], agent: .none, effect: .external,
                summary: L10n.tr("Uruchamia \(kind.displayName) w panelu agenta; katalog roboczy = katalog aktywnego panelu."))
            ) { [weak self] _ in
                try await self?.launch(kind)
                return .ok
            })
        }
        list.append(Command(CommandDescriptor(
            id: "agent.togglePane", title: L10n.tr("Panel agenta"), category: .agent, tc: ["ctrl+alt+0"],
            agent: .none, effect: .uiState, summary: L10n.tr("Pokazuje lub ukrywa panel agenta z aktywnością."))
        ) { [weak self] _ in
            self?.togglePane()
            return .ok
        })
        list.append(Command(CommandDescriptor(
            id: "agent.undoSession", title: L10n.tr("Cofnij sesję agenta…"), category: .agent,
            agent: .none, effect: .modifiesFiles, summary: L10n.tr("Cofa wszystkie operacje na plikach wykonane przez wybraną sesję agenta, w odwrotnej kolejności."))
        ) { [weak self] _ in
            guard let self, let id = self.pane.selectedSessionID else { throw CommandError.notAvailable(L10n.tr("Brak sesji agenta")) }
            self.undoSession(id)
            return .ok
        })
        list.append(Command(CommandDescriptor(
            id: "agent.endSession", title: L10n.tr("Zakończ sesję agenta"), category: .agent,
            agent: .none, effect: .external, summary: L10n.tr("Kończy proces CLI i unieważnia token sesji."))
        ) { [weak self] _ in
            if let self, let id = self.pane.selectedSessionID { self.endSession(id) }
            return .ok
        })
        list.append(Command(CommandDescriptor(
            id: "agent.showLog", title: L10n.tr("Dziennik agentów…"), category: .agent,
            agent: .none, effect: .uiState, summary: L10n.tr("Przeglądarka dziennika wywołań API agentów."))
        ) { [weak self] _ in
            self?.showLog()
            return .ok
        })
        return list
    }

    // MARK: Uruchamianie

    func launch(_ kind: AgentKind) async throws {
        let directory = workspace.activeTab.path
        guard FileManager.default.isExecutableFile(atPath: bridgePath) else {
            throw CommandError.notAvailable(L10n.tr("Brak mostu bifold-mcp w pakiecie aplikacji (\(bridgePath))."))
        }
        guard let executable = await Self.which(kind.executable) else {
            throw CommandError.notAvailable(L10n.tr("Nie znaleziono polecenia „\(kind.executable)” w PATH powłoki logowania."))
        }
        let settings = workspace.settings.agent
        if kind == .antigravity { try await ensureAntigravityRegistration(executable: executable) }

        let (session, token) = controller.createSession(kind: kind, directory: directory)
        let sessionDir = workspace.paths.run.appending(path: "session-\(session.id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let spec = AgentLauncher.spec(
            kind: kind, bridge: bridgePath, socket: controller.socketURL.path, token: token, directory: directory.path,
            strict: settings.strictMode, sessionDirectory: sessionDir.path, executable: executable)
        for (path, contents) in spec.files {
            try Data(contents.utf8).write(to: URL(filePath: path), options: .atomic)
            chmod(path, 0o600)
        }

        var env = ProcessInfo.processInfo.environment
        // Znaczniki sesji CLI, z której ewentualnie uruchomiono aplikację, nie mogą przeciekać do agenta.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_") || key == Bridge.tokenVariable {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        for (k, v) in spec.environment { env[k] = v }
        let terminal = pane.addSession(session: session, warnings: spec.warnings, command: spec.displayCommand) { [weak self] in
            self?.controller.closeSession(session.id)
            try? FileManager.default.removeItem(at: sessionDir)
        }
        showPane()
        terminal.startProcess(
            executable: spec.shell, args: spec.shellArguments, environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil, currentDirectory: directory.path)
        session.cliPID = terminal.process.shellPid
        terminal.window?.makeFirstResponder(terminal)
    }

    /// Ścieżka polecenia w PATH powłoki logowania użytkownika.
    static func which(_ name: String) async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return try? await runBlocking(qos: .userInitiated) { () -> String? in
            let p = Process()
            p.executableURL = URL(filePath: shell)
            p.arguments = ["-l", "-c", "command -v \(name)"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 && path.hasPrefix("/") ? path : nil
        }
    }

    /// Antigravity nie ma konfiguracji MCP na sesję — jednorazowa rejestracja za zgodą (PROMPT.md 5.1).
    private func ensureAntigravityRegistration(executable: String) async throws {
        let list = try? await runBlocking(qos: .userInitiated) { () -> String in
            let p = Process()
            p.executableURL = URL(filePath: executable)
            p.arguments = ["mcp", "list"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        if let list, list.contains(bridgePath) { return }
        guard let ui = workspace.ui, await ui.confirm(
            title: L10n.tr("Zarejestrować serwer MCP w Antigravity?"),
            message: L10n.tr("Antigravity nie pozwala podać serwera MCP tylko dla jednej sesji. Bifold doda na stałe serwer „bifold” (agy mcp add). Bez tokenu sesji most odrzuca każde połączenie, więc poza sesjami uruchomionymi z Bifolda serwer jest bezużyteczny."),
            confirmTitle: L10n.tr("Zarejestruj"), destructive: false)
        else { throw CommandError.cancelledByUser }
        let args = AgentLauncher.spec(kind: .antigravity, bridge: bridgePath, socket: controller.socketURL.path, token: "", directory: "/", strict: true, sessionDirectory: "/").persistentRegistration ?? []
        let status = try await runBlocking(qos: .userInitiated) { () -> Int32 in
            let p = Process()
            p.executableURL = URL(filePath: executable)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        guard status == 0 else { throw CommandError.notAvailable(L10n.tr("agy mcp add zakończył się błędem (\(status))")) }
    }

    // MARK: Sesje

    func endSession(_ id: String) {
        pane.terminateSession(id)
        controller.closeSession(id)
    }

    func undoSession(_ id: String) {
        let plan = workspace.fileOps.undoPlan(forAgentSession: id)
        guard !plan.isEmpty else {
            workspace.ui?.showMessage(L10n.tr("Sesja nie zmieniła żadnych plików"))
            return
        }
        Task {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Cofnąć sesję agenta (\(plan.steps.count) kroków)?")
            let steps = plan.steps.prefix(60).map { step -> String in
                let op = step.preview
                let mark = step.conflict.map { " ⚠︎ " + $0.message } ?? ""
                return "\(op.kind): \(op.source?.path ?? "") \(op.destination.map { "→ " + $0.path } ?? "")\(mark)"
            }.joined(separator: "\n")
            alert.informativeText = L10n.tr("Operacje odwrotne w odwrotnej kolejności. Konflikty: \(plan.conflicts.count).")
            alert.accessoryView = Self.textAccessory(steps + (plan.steps.count > 60 ? "\n…" : ""))
            alert.addButton(withTitle: L10n.tr("Cofnij"))
            if !plan.conflicts.isEmpty { alert.addButton(withTitle: L10n.tr("Cofnij z wymuszeniem")) }
            alert.addButton(withTitle: L10n.tr("Anuluj"))
            let response = await present(alert)
            let force: Bool
            switch response {
            case .alertFirstButtonReturn: force = false
            case .alertSecondButtonReturn where !plan.conflicts.isEmpty: force = true
            default: return
            }
            let result = await workspace.fileOps.execute(plan, force: force)
            await workspace.left.activeTab.reload()
            await workspace.right.activeTab.reload()
            workspace.ui?.showMessage(L10n.tr("Cofnięto: \(result.performed), pominięto: \(result.skipped.count), błędy: \(result.errors.count)"))
        }
    }

    // MARK: Zatwierdzanie

    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        // Kolejne prośby czekają, aż poprzednia zostanie rozpatrzona.
        let previous = approvalChain
        let task = Task<Bool, Never> {
            await previous?.value
            return await showApproval(request)
        }
        approvalChain = Task { _ = await task.value }
        return await task.value
    }

    private func showApproval(_ r: ApprovalRequest) async -> Bool {
        showPane()
        NSApp.requestUserAttention(.criticalRequest)
        let p = r.preview
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("\(r.agent.displayName) chce wykonać: \(r.title)")
        var info = p.summary
        info += "\n" + L10n.tr("Elementy: \(p.fileCount), rozmiar: \(Format.bytes(p.totalBytes))")
        if !p.conflicts.isEmpty { info += "\n⚠︎ " + L10n.tr("Konflikty: \(p.conflicts.count)") }
        alert.informativeText = info
        var lines = p.operations.prefix(200).map { op in
            "\(op.conflict ? "⚠︎ " : "")\(op.kind)  \(op.source?.path ?? "")\(op.destination.map { "  →  " + $0.path } ?? "")\(op.bytes > 0 ? "  (\(Format.bytes(op.bytes)))" : "")"
        }
        if p.operations.count > 200 { lines.append("…") }
        if !p.conflicts.isEmpty { lines += ["", L10n.tr("Istniejące elementy docelowe:")] + p.conflicts.prefix(50).map { "  " + $0 } }
        let args = r.arguments.values.filter { !$0.key.hasPrefix("__") }
        lines += ["", L10n.tr("Argumenty: \(JSONValue.object(args).description)")]
        alert.accessoryView = Self.textAccessory(lines.joined(separator: "\n"))
        // Zgoda wymaga świadomego kliknięcia: Enter nic nie zatwierdza (użytkownik mógł właśnie
        // pisać w terminalu agenta), Esc odrzuca, a „Zatwierdź” jest aktywny dopiero po chwili.
        let approve = alert.addButton(withTitle: L10n.tr("Zatwierdź"))
        approve.keyEquivalent = ""
        approve.isEnabled = false
        let reject = alert.addButton(withTitle: L10n.tr("Odrzuć"))
        reject.keyEquivalent = "\u{1b}"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { approve.isEnabled = true }
        return await present(alert) == .alertFirstButtonReturn
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = mainWindow?.window, window.attachedSheet == nil else { return alert.runModal() }
        return await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
    }

    static func textAccessory(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 620, height: 220)
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = text
        scroll.hasVerticalScroller = true
        return scroll
    }

    // MARK: Panel i dziennik

    func togglePane() {
        if pane.isHidden { showPane() } else { mainWindow?.setAgentPane(visible: false) }
    }

    func showPane() {
        mainWindow?.setAgentPane(visible: true)
    }

    func showLog() {
        if logWindow == nil { logWindow = AgentLogWindowController(directory: workspace.paths.agentLogs) }
        logWindow?.showWindow(nil)
        logWindow?.reload()
    }
}
