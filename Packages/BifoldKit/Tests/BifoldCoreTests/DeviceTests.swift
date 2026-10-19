import Foundation
import Testing
@testable import BifoldCore

@Suite struct DeviceParserTests {
    @Test func afcLongListing() {
        let text = """
        drwxr-xr-x    1 mobile mobile        160 05 Mar 2026 10:11:12 100APPLE
        -rw-r--r--    1 mobile mobile    2345678 06 Mar 2026 08:00:01 IMG_0001.HEIC
        -rw-r--r--    1 mobile mobile         12 06 Mar 2026 08:00:01 Zdjęcie z wakacji.jpg
        lrwxrwxrwx    1 mobile mobile          4 01 Jan 2026 00:00:00 link
        """
        let dir = VFSPath(provider: ProviderID("device:x"), path: "/DCIM")
        let items = AFCDeviceFS.parseLongListing(text, in: dir)
        #expect(items.map(\.name) == ["100APPLE", "IMG_0001.HEIC", "Zdjęcie z wakacji.jpg", "link"])
        #expect(items[0].isDirectory && items[1].size == 2_345_678 && items[3].kind == .symlink)
        #expect(items[1].path.path == "/DCIM/IMG_0001.HEIC")
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.month, from: items[1].modified!) == 3)
    }

    @Test func mtpDetectJSON() {
        let json = Data(#"[{"index":0,"vendor":"Samsung","product":"Galaxy models (MTP)","vid":1256,"pid":26720,"bus":2,"dev":5}]"#.utf8)
        #expect(DeviceDetector.parseMTPDetect(json) == [DeviceInfo(id: "0", kind: .android, name: "Samsung Galaxy models")])
        #expect(DeviceDetector.parseMTPDetect(Data("[]".utf8)).isEmpty)
    }

    /// Fałszywy `bifold-mtp`: protokół jak prawdziwy pomocnik; nośnik pojawia się dopiero po „Zezwól”
    /// (plik `allowed`), folder DCIM ma podfolder i plik.
    func fakeHelper(_ tmp: TempDir) throws -> String {
        let path = tmp.url.appending(path: "bifold-mtp").path
        let script = """
        #!/bin/bash
        D="$(dirname "$0")"
        if [ "$1" = detect ]; then echo '[{"index":0,"vendor":"Samsung","product":"Galaxy models (MTP)"}]'; exit 0; fi
        # Jak Samsung: nośniki widzi tylko sesja otwarta po „Zezwól” (telefon łączy się z USB od nowa).
        if [ -f "$D/allowed" ]; then ALLOWED=1; else ALLOWED=0; fi
        echo session >> "$D/sessions"
        storages() { if [ $ALLOWED = 1 ]; then echo '[{"id":65537,"name":"Pamięć wewnętrzna","total":256000000000,"free":100000000000}]'; else echo '[]'; fi; }
        echo '{"ok":true,"model":"SM-F776B","name":"Galaxy","storages":'"$(storages)"'}'
        while read -r cmd a b; do
          echo "$cmd $a $b" >> "$D/log"
          case "$cmd" in
            storages) echo '{"ok":true,"storages":'"$(storages)"'}' ;;
            list)
              if [ "$b" = 4294967295 ]; then echo '{"ok":true,"items":[{"id":10,"name":"DCIM","size":0,"mtime":0,"folder":true},{"id":11,"name":"notatka ąę.txt","size":5,"mtime":1760000000,"folder":false}]}'
              elif [ "$b" = 10 ]; then echo '{"ok":true,"items":[{"id":20,"name":"Camera","size":0,"mtime":0,"folder":true},{"id":21,"name":"IMG_1.jpg","size":3,"mtime":1760000000,"folder":false}]}'
              else echo '{"ok":true,"items":[]}'; fi ;;
            get) printf 'plik-%s' "$a" > "$b"; echo '{"ok":true}' ;;
            quit) exit 0 ;;
            *) echo '{"ok":false,"error":"Nieznane polecenie"}' ;;
          esac
        done
        """
        try Data(script.utf8).write(to: URL(filePath: path))
        chmod(path, 0o755)
        return path
    }

    @Test func mtpFolderByFolderWithPermissionPrompt() async throws {
        let tmp = try TempDir()
        let helper = try fakeHelper(tmp)
        #expect(DeviceDetector.androids(helper: helper).map(\.name) == ["Samsung Galaxy models"])
        let fs = try MTPDeviceFS(device: DeviceInfo(id: "0", kind: .android, name: "Samsung"), helperPath: helper)
        defer { fs.close() }
        #expect(fs.model == "SM-F776B")

        // Bez „Zezwól” na telefonie: jasny komunikat zamiast pustego panelu; sesja zostaje.
        do {
            _ = try await fs.list(fs.root, options: ListOptions())
            Issue.record("bez zgody na telefonie listing powinien zgłosić błąd")
        } catch {
            #expect(error.localizedDescription.contains("Zezwól"))
        }
        FileManager.default.createFile(atPath: tmp.url.path + "/allowed", contents: Data())
        // Odświeżenie po zgodzie otwiera nową sesję (stara nigdy nie zobaczy nośników).
        let root = try await fs.list(fs.root, options: ListOptions())
        #expect(try tmp.read("sessions").split(separator: "\n").count >= 3)
        #expect(root.map(\.name) == ["Pamięć wewnętrzna"] && root[0].isDirectory)

        // Folder po folderze — bez wczytywania całego telefonu.
        let storage = fs.root.appending("Pamięć wewnętrzna")
        let top = try await fs.list(storage, options: ListOptions())
        #expect(top.map(\.name) == ["DCIM", "notatka ąę.txt"] && top[1].size == 5)
        let dcim = try await fs.list(storage.appending("DCIM"), options: ListOptions())
        #expect(dcim.map(\.name) == ["Camera", "IMG_1.jpg"])
        let log = try tmp.read("log")
        #expect(log.contains("list 65537 4294967295") && log.contains("list 65537 10") && !log.contains("list 65537 20"))

        // Pobieranie (katalogi rekurencyjnie) i wolne miejsce nośnika.
        let (temp, items) = try fs.extract([storage.appending("DCIM")], toTemporaryIn: tmp.path, isCancelled: { false })
        #expect(try String(contentsOfFile: items[0].path + "/IMG_1.jpg", encoding: .utf8) == "plik-21")
        #expect(FileManager.default.fileExists(atPath: items[0].path + "/Camera"))
        try? FileManager.default.removeItem(atPath: temp.path)
        let v = try await fs.volumeInfo(for: storage)
        #expect(v.totalCapacity == 256_000_000_000 && v.availableCapacity == 100_000_000_000)

        fs.close()
        let finalLog = try tmp.read("log")
        #expect(!fs.isSessionRunning || finalLog.hasSuffix("quit  \n"))
    }

    @Test func noDevicesConnectedIsHandled() {
        #expect(DeviceDetector.iPhones(toolsDirectory: "/nonexistent").isEmpty)
        #expect(DeviceDetector.androids(helper: "/nonexistent").isEmpty)
    }
}
