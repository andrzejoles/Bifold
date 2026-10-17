import BifoldCore
import BifoldWorkspace
import Foundation
import MCP

/// Narzędzia MCP jako widok na rejestr komend (ARCHITECTURE.md §8).
public enum ToolCatalog {
    public struct Entry: Sendable {
        public let tool: String
        public let command: CommandID
        /// Stałe argumenty dokładane do wywołania (np. `view.setMode`).
        public let fixed: [String: JSONValue]

        init(_ tool: String, _ command: CommandID, fixed: [String: JSONValue] = [:]) {
            self.tool = tool
            self.command = command
            self.fixed = fixed
        }
    }

    public static let runCommand = "run_command"
    public static let viaRunCommandKey = "__viaRunCommand"

    public static let entries: [Entry] = [
        Entry("get_state", "agent.state"),
        Entry("get_selection", "agent.selection"),
        Entry("list_directory", "agent.list"),
        Entry("file_info", "agent.fileInfo"),
        Entry("read_file", "agent.readFile"),
        Entry("dir_size", "selection.calculateSizes"),
        Entry("list_jobs", "queue.list"),
        Entry("navigate", "panel.navigate"),
        Entry("switch_panel", "panel.switch"),
        Entry("set_cursor", "panel.setCursor"),
        Entry("tab_open", "tab.new"),
        Entry("tab_close", "tab.close"),
        Entry("tab_switch", "tab.select"),
        Entry("set_view", "view.setMode"),
        Entry("set_sort", "view.sortBy"),
        Entry("select", "selection.byMask"),
        Entry("deselect", "selection.deselectByMask"),
        Entry("set_selection", "selection.set"),
        Entry("quick_filter", "panel.quickFilter"),
        Entry("open_preview", "view.previewPanel"),
        Entry("copy_paths_to_clipboard", "clipboard.copyPaths"),
        Entry("color_rules_get", "colors.get"),
        Entry("color_rules_set", "colors.set"),
        Entry("copy", "file.copy"),
        Entry("move", "file.move"),
        Entry("trash", "file.trash"),
        Entry("mkdir", "file.mkdir"),
        Entry("new_file", "file.newFile"),
        Entry("rename", "file.rename"),
        Entry("set_attributes", "file.attributes"),
        Entry("set_tags", "file.tags"),
        Entry("undo", "edit.undo"),
        Entry("queue_pause", "queue.pause"),
        Entry("queue_resume", "queue.resume"),
        Entry("queue_cancel", "queue.cancel"),
        Entry("queue_speed_limit", "queue.setSpeedLimit"),
        Entry("search", "search.find"),
        Entry("spotlight_search", "search.spotlight"),
        Entry("saved_search_run", "search.runSaved"),
        Entry("saved_search_list", "search.listSaved"),
        Entry("find_duplicates", "search.duplicates"),
        Entry("multi_rename", "file.multiRename"),
        Entry("checksum", "file.checksumCreate"),
        Entry("checksum_verify", "file.checksumVerify"),
        Entry("split_file", "file.split"),
        Entry("join_files", "file.join"),
    ]

    public static func entry(named name: String) -> Entry? { entries.first { $0.tool == name } }

    /// Schemat JSON argumentów z parametrów komendy.
    static func schema(for params: [CommandParameter]) -> Value {
        var properties: [String: Value] = [:]
        for p in params {
            var prop: [String: Value] = ["description": .string(p.description)]
            switch p.type {
            case .string, .path: prop["type"] = "string"
            case .paths: prop["type"] = "array"; prop["items"] = ["type": "string"]
            case .integer: prop["type"] = "integer"
            case .boolean: prop["type"] = "boolean"
            case .object: prop["type"] = "object"
            }
            if let allowed = p.allowedValues { prop["enum"] = .array(allowed.map { .string($0) }) }
            properties[p.name] = .object(prop)
        }
        let required = params.filter(\.required).map { Value.string($0.name) }
        return .object(["type": "object", "properties": .object(properties), "required": .array(required), "additionalProperties": false])
    }

    static func levelNote(_ level: AgentAccess) -> String {
        switch level {
        case .approval: " [Wymaga zatwierdzenia przez użytkownika — aplikacja pokaże podgląd skutków.]"
        case .read: " [Tylko odczyt.]"
        default: ""
        }
    }

    /// Narzędzia widoczne dla sesji (poziom > Brak).
    @MainActor
    public static func tools(for session: AgentSession, registry: CommandRegistry, settings: AgentSettings) -> [Tool] {
        var tools: [Tool] = []
        for e in entries {
            guard let command = registry.command(e.command) else { continue }
            let level = AgentPolicy.effectiveAccess(command: command.descriptor, session: session, settings: settings)
            guard level > .none else { continue }
            let params = command.descriptor.parameters.filter { e.fixed[$0.name] == nil }
            let readOnly = command.descriptor.effect == .none || command.descriptor.effect == .uiState
            tools.append(Tool(
                name: e.tool,
                description: command.descriptor.summary + levelNote(level),
                inputSchema: schema(for: params),
                annotations: .init(title: command.descriptor.title, readOnlyHint: readOnly, destructiveHint: command.descriptor.effect == .modifiesFiles)))
        }
        let available = registry.commands.filter {
            AgentPolicy.effectiveAccess(command: $0.descriptor, session: session, settings: settings, viaRunCommand: true) > .none
        }
        if !available.isEmpty {
            let list = available.map { "\($0.id.rawValue) — \($0.descriptor.title)" }.joined(separator: "; ")
            tools.append(Tool(
                name: runCommand,
                description: "Wywołuje dowolną komendę aplikacji z rejestru (poziom dostępu: nie wyższy niż „Za zgodą” i nie wyższy niż poziom komendy). Dostępne: \(list)",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "command": .object(["type": "string", "description": "Identyfikator komendy, np. view.toggleTree"]),
                        "arguments": .object(["type": "object", "description": "Argumenty komendy"]),
                    ]),
                    "required": ["command"],
                ]),
                annotations: .init(title: "Komenda aplikacji")))
        }
        return tools
    }
}

extension JSONValue {
    init(mcp value: MCP.Value) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .int(Int64(i))
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map(JSONValue.init(mcp:)))
        case .object(let o): self = .object(o.mapValues(JSONValue.init(mcp:)))
        case .data(mimeType: _, let d): self = .string(d.base64EncodedString())
        }
    }
}
