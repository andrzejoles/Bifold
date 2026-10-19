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
        setenv("BIFOLD_MTP_HELPER", helper, 1)
        defer { unsetenv("BIFOLD_MTP_HELPER") }
        let (ws, _) = try await makeWorkspace(tmp)

        try await ws.invoke("device.open", CommandArguments(["id": "0"]))
        let tab = ws.left.activeTab
        #expect(tab.path.provider.rawValue == "device:mtp-0" && tab.items.isEmpty)
        #expect(tab.loadError?.contains("Zezwól") == true && tab.customTitle == "🤖 SM-F776B")

        FileManager.default.createFile(atPath: tmp.url.path + "/allowed", contents: Data())
        try await ws.invoke("panel.refresh")
        #expect(tab.items.map(\.name).contains("Pamięć wewnętrzna") && tab.loadError == nil)

        try await ws.invoke("remote.disconnect")
        #expect(tab.path == tmp.path && (try? ws.providers.provider(for: ProviderID("device:mtp-0"))) == nil)
        #expect(tmp.exists("quit"), "sesja MTP zamknięta")
    }
}
