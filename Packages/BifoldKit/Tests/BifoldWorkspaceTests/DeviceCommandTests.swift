import Foundation
import Testing
@testable import BifoldCore
@testable import BifoldWorkspace

/// Telefon z Androidem przez komendy: bez „Zezwól”, po zgodzie (Ctrl+R) i zamknięcie.
@MainActor @Suite(.serialized) struct DeviceCommandTests {
    @Test func androidWithoutPermissionThenRefreshThenClose() async throws {
        let tmp = try TempDir()
        let helper = tmp.url.appending(path: "bifold-mtp").path
        let script = """
        #!/bin/bash
        D="$(dirname "$0")"
        if [ "$1" = detect ]; then echo '[{"index":0,"vendor":"Samsung","product":"Galaxy models (MTP)"}]'; exit 0; fi
        if [ -f "$D/allowed" ]; then S='[{"id":1,"name":"Pamięć wewnętrzna","total":10,"free":5}]'; else S='[]'; fi
        echo '{"ok":true,"model":"SM-F776B","name":"Galaxy","storages":'"$S"'}'
        while read -r cmd a b; do
          case "$cmd" in
            storages) echo '{"ok":true,"storages":'"$S"'}' ;;
            list) echo '{"ok":true,"items":[{"id":10,"name":"DCIM","size":0,"mtime":0,"folder":true}]}' ;;
            quit) echo quit >> "$D/quit"; exit 0 ;;
          esac
        done
        """
        try Data(script.utf8).write(to: URL(filePath: helper))
        chmod(helper, 0o755)
        // Pomocnik dla tego testu (wartość zadania) — `setenv` nie jest bezpieczne przy zestawach równoległych.
        try await DeviceDetector.$mtpHelperOverride.withValue(helper) {
            try await androidFlow(tmp)
        }
    }

    func androidFlow(_ tmp: TempDir) async throws {
        let (ws, _) = try await makeWorkspace(tmp)
        let gate = AllowAllGate()
        ws.agentGate = gate
        defer { withExtendedLifetime(gate) {} }
        // Nazwy z telefonu dla agenta jako dane niezaufane.
        let listed = try await ws.invoke("device.list", invoker: .agent(sessionID: "t", agentName: "t"))
        #expect(listed.value?["untrusted"] == true && "\(listed.value?["content"] ?? .null)".contains("Samsung"))

        try await ws.invoke("device.open", CommandArguments(["id": "0"]))
        let tab = ws.left.activeTab
        #expect(ws.left.tabs.count == 2 && ws.left.tabs[0].path == tmp.path, "telefon w nowej karcie")
        #expect(tab.path.provider.rawValue == "device:mtp-0" && tab.items.isEmpty)
        #expect(tab.loadError?.contains("Zezwól") == true && tab.customTitle == "🤖 SM-F776B")

        FileManager.default.createFile(atPath: tmp.url.path + "/allowed", contents: Data())
        try await ws.invoke("panel.refresh")
        #expect(tab.items.map(\.name).contains("Pamięć wewnętrzna") && tab.loadError == nil)

        try await ws.invoke("remote.disconnect")
        #expect(ws.left.tabs.count == 1 && ws.left.activeTab.path == tmp.path, "karta telefonu zamknięta")
        #expect((try? ws.providers.provider(for: ProviderID("device:mtp-0"))) == nil)
        #expect(tmp.exists("quit"), "sesja MTP zamknięta")

        // Otwarcie przez agenta: model telefonu w wyniku niezaufanym, nie w komunikacie.
        FileManager.default.createFile(atPath: tmp.url.path + "/allowed", contents: Data())
        let opened = try await ws.invoke("device.open", CommandArguments(["id": "0"]), invoker: .agent(sessionID: "t", agentName: "t"))
        #expect(opened.message == nil && opened.value?["untrusted"] == true && opened.value?["content"]?["name"] == "SM-F776B")
        await ws.closeDevice(ProviderID("device:mtp-0"))
    }

    /// Dwa telefony: numer z `detect` zmienia się z kolejnością — otwarcie telefonu B nie może zwrócić
    /// otwartej sesji telefonu A (dostawca identyfikowany po USB, D51).
    @Test func reorderedPhonesGetTheirOwnSessions() async throws {
        let tmp = try TempDir()
        let helper = tmp.url.appending(path: "bifold-mtp").path
        // `detect`: kolejność zależy od pliku `swapped`; `serve <nr> <vid> …` — model wg vid.
        let script = """
        #!/bin/bash
        D="$(dirname "$0")"
        A='"vendor":"Samsung","product":"A","vid":1,"pid":10,"bus":1,"dev":1'
        B='"vendor":"Google","product":"B","vid":2,"pid":20,"bus":1,"dev":2'
        if [ "$1" = detect ]; then
          if [ -f "$D/swapped" ]; then echo "[{\\"index\\":0,$B},{\\"index\\":1,$A}]"; else echo "[{\\"index\\":0,$A},{\\"index\\":1,$B}]"; fi
          exit 0
        fi
        if [ "$3" = 2 ]; then M=telefon-B; else M=telefon-A; fi
        echo '{"ok":true,"model":"'"$M"'","name":"x","storages":[{"id":1,"name":"Pamięć","total":10,"free":5}]}'
        while read -r cmd a b; do
          case "$cmd" in
            storages) echo '{"ok":true,"storages":[{"id":1,"name":"Pamięć","total":10,"free":5}]}' ;;
            list) echo '{"ok":true,"items":[]}' ;;
            quit) exit 0 ;;
          esac
        done
        """
        try Data(script.utf8).write(to: URL(filePath: helper))
        chmod(helper, 0o755)
        try await DeviceDetector.$mtpHelperOverride.withValue(helper) {
            try await reorderedFlow(tmp)
        }
    }

    func reorderedFlow(_ tmp: TempDir) async throws {
        let (ws, _) = try await makeWorkspace(tmp)
        defer { withExtendedLifetime(tmp) {} }  // pomocnik leży w katalogu testu
        defer {
            for tab in ws.left.tabs + ws.right.tabs { (try? ws.providers.provider(for: tab.path.provider) as? MTPDeviceFS)?.close() }
        }

        try await ws.invoke("device.open", CommandArguments(["id": "0"]))
        #expect(ws.left.activeTab.customTitle == "🤖 telefon-A")
        let first = ws.left.activeTab.path.provider
        FileManager.default.createFile(atPath: tmp.url.path + "/swapped", contents: Data())
        try await ws.invoke("device.open", CommandArguments(["id": "0"]))
        #expect(ws.left.activeTab.customTitle == "🤖 telefon-B", "numer 0 to teraz telefon B")
        #expect(ws.left.activeTab.path.provider != first)
        // Telefon A pod nowym numerem — ta sama (otwarta) sesja.
        try await ws.invoke("device.open", CommandArguments(["id": "1"]))
        #expect(ws.left.activeTab.path.provider == first && ws.left.activeTab.customTitle == "🤖 telefon-A")
    }
}
