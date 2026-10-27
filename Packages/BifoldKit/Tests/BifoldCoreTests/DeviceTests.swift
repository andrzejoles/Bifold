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
        -rw-r--r--    1 mobile mobile          1 01 Jan 2026 00:00:00 a/b
        -rw-r--r--    1 mobile mobile          1 01 Jan 2026 00:00:00 ..
        -rw-r--r--    1 mobile mobile          1 01 Jan 2026 00:00:00 zły\u{1B}[2Jznak
        """
        let dir = VFSPath(provider: ProviderID("device:x"), path: "/DCIM")
        let items = AFCDeviceFS.parseLongListing(text, in: dir)
        // Nazwy z `/`, `..` albo znakami sterującymi pomijane (D46) — trafiłyby do ścieżek lokalnych.
        #expect(items.map(\.name) == ["100APPLE", "IMG_0001.HEIC", "Zdjęcie z wakacji.jpg", "link"])
        #expect(items[0].isDirectory && items[1].size == 2_345_678 && items[3].kind == .symlink)
        #expect(items[1].path.path == "/DCIM/IMG_0001.HEIC")
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.month, from: items[1].modified!) == 3)
    }

    /// Dwa iPhone’y z tym samym układem mają wspólny początek UDID — identyfikator dostawcy z pełnego UDID.
    @Test func afcProviderIDUsesFullUDID() {
        let a = AFCDeviceFS(device: DeviceInfo(id: "00008110-001A2B3C4D5E6F70", kind: .iPhone, name: "A"), afcclient: "/x")
        let b = AFCDeviceFS(device: DeviceInfo(id: "00008110-001A2B3C4D5E6F71", kind: .iPhone, name: "B"), afcclient: "/x")
        #expect(a.id != b.id)
        #expect(a.id.rawValue == "device:00008110-001A2B3C4D5E6F70")
    }

    /// Anulowanie `afcclient get -rf` kończy narzędzie (wcześniej czekało do końca) i nie zostawia
    /// katalogu tymczasowego; katalog tymczasowy jest prywatny (0700).
    @Test func afcCancelStopsToolAndCleansUp() throws {
        let tmp = try TempDir()
        let tool = tmp.url.path + "/afcclient"
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: URL(filePath: tool))
        chmod(tool, 0o755)
        try tmp.dir("cel")
        let fs = AFCDeviceFS(device: DeviceInfo(id: "U", kind: .iPhone, name: "i"), afcclient: tool)
        let start = Date()
        #expect(throws: VFSError.cancelled) {
            _ = try fs.extract([fs.root.appending("DCIM")], toTemporaryIn: tmp.path.appending("cel"), isCancelled: { Date().timeIntervalSince(start) > 0.3 })
        }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path + "/cel").isEmpty, "katalog tymczasowy usunięty")
        let temp = try makeDeviceTemp(in: tmp.path)
        #expect((try FileManager.default.attributesOfItem(atPath: temp.path)[.posixPermissions] as? Int) == 0o700)
    }

    @Test func mtpDetectJSON() {
        let json = Data(#"[{"index":0,"vendor":"Samsung","product":"Galaxy models (MTP)","vid":1256,"pid":26720,"bus":2,"dev":5}]"#.utf8)
        #expect(DeviceDetector.parseMTPDetect(json) == [DeviceInfo(id: "0", kind: .android, name: "Samsung Galaxy models", usb: "1256 26720 2 5")])
        #expect(DeviceDetector.parseMTPDetect(Data(#"[{"index":1,"vendor":"X"}]"#.utf8)) == [DeviceInfo(id: "1", kind: .android, name: "X")])
        #expect(DeviceDetector.parseMTPDetect(Data("[]".utf8)).isEmpty)
    }

    /// Sesja (i każda ponowna sesja) otwierana po identyfikatorze USB — po odłączeniu jednego z dwóch
    /// telefonów numer z listy wskazywałby inny telefon.
    @Test func mtpSessionIdentifiedByUSB() throws {
        let tmp = try TempDir()
        let helper = try fakeHelper(tmp)
        FileManager.default.createFile(atPath: tmp.url.path + "/allowed", contents: Data())
        let fs = try MTPDeviceFS(device: DeviceInfo(id: "0", kind: .android, name: "S", usb: "1256 26720 2 5"), helperPath: helper)
        try fs.reopen()
        fs.close()
        #expect(try tmp.read("args").split(separator: "\n") == ["serve 0 1256 26720 2 5", "serve 0 1256 26720 2 5"])
        // Po zamknięciu: bez nowej sesji.
        #expect(throws: VFSError.cancelled) { try fs.reopen() }
        #expect(throws: VFSError.cancelled) { _ = try fs.storages() }
    }

    /// Pomocnik, który przestał czytać polecenia (zamknięty stdin): zapis daje błąd, a nie SIGPIPE,
    /// który zabiłby aplikację.
    @Test func mtpWriteToDeadPipeDoesNotKill() throws {
        let tmp = try TempDir()
        let helper = tmp.url.path + "/bifold-mtp"
        try Data("#!/bin/bash\necho '{\"ok\":true,\"model\":\"M\",\"storages\":[]}'\nexec 0<&-\nexec /bin/sleep 5\n".utf8).write(to: URL(filePath: helper))
        chmod(helper, 0o755)
        let fs = try MTPDeviceFS(device: DeviceInfo(id: "0", kind: .android, name: "S"), helperPath: helper)
        defer { fs.close() }
        usleep(200_000)
        let start = Date()
        #expect(throws: (any Error).self) { _ = try fs.helper.request("storages", timeout: 3) }
        #expect(Date().timeIntervalSince(start) < 2, "błąd zapisu (EPIPE), nie limit czasu")
    }

    /// Fałszywy `bifold-mtp`: protokół jak prawdziwy pomocnik; nośnik pojawia się dopiero po „Zezwól”
    /// (plik `allowed`), folder DCIM ma podfolder i plik, folder Inne — nazwy, których nie wolno użyć
    /// w ścieżce, i plik, którego pobieranie trwa bez końca.
    func fakeHelper(_ tmp: TempDir) throws -> String {
        let path = tmp.url.appending(path: "bifold-mtp").path
        let script = """
        #!/bin/bash
        D="$(dirname "$0")"
        if [ "$1" = detect ]; then echo '[{"index":0,"vendor":"Samsung","product":"Galaxy models (MTP)"}]'; exit 0; fi
        echo "$*" >> "$D/args"
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
              if [ "$b" = 4294967295 ]; then echo '{"ok":true,"items":[{"id":10,"name":"DCIM","size":0,"mtime":0,"folder":true},{"id":11,"name":"notatka ąę.txt","size":5,"mtime":1760000000,"folder":false},{"id":12,"name":"Inne","size":0,"mtime":0,"folder":true}]}'
              elif [ "$b" = 10 ]; then echo '{"ok":true,"items":[{"id":20,"name":"Camera","size":0,"mtime":0,"folder":true},{"id":21,"name":"IMG_1.jpg","size":3,"mtime":1760000000,"folder":false}]}'
              elif [ "$b" = 12 ]; then echo '{"ok":true,"items":[{"id":30,"name":"..","size":0,"mtime":0,"folder":true},{"id":31,"name":"a/b","size":1,"mtime":0,"folder":false},{"id":32,"name":"x\\nget 99 /tmp/zle","size":1,"mtime":0,"folder":false},{"id":35,"name":"","size":1,"mtime":0,"folder":false},{"id":33,"name":"ok.jpg","size":2,"mtime":0,"folder":false},{"id":34,"name":"wolny.mp4","size":9,"mtime":0,"folder":false}]}'
              else echo '{"ok":true,"items":[]}'; fi ;;
            get) if [ "$a" = 34 ]; then sleep 10; fi; printf 'plik-%s' "$a" > "$b"; echo '{"ok":true}' ;;
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
        #expect(top.map(\.name) == ["DCIM", "notatka ąę.txt", "Inne"] && top[1].size == 5)
        let dcim = try await fs.list(storage.appending("DCIM"), options: ListOptions())
        #expect(dcim.map(\.name) == ["Camera", "IMG_1.jpg"])
        let log = try tmp.read("log")
        #expect(log.contains("list 65537 4294967295") && log.contains("list 65537 10") && !log.contains("list 65537 20"))

        // Pobieranie (katalogi rekurencyjnie) i wolne miejsce nośnika.
        let (temp, items) = try fs.extract([storage.appending("DCIM")], toTemporaryIn: tmp.path, isCancelled: { false })
        #expect(try String(contentsOfFile: items[0].path + "/IMG_1.jpg", encoding: .utf8) == "plik-21")
        #expect(FileManager.default.fileExists(atPath: items[0].path + "/Camera"))
        #expect(Quarantine.isMarked(items[0].path + "/IMG_1.jpg"), "plik z telefonu z atrybutem kwarantanny")
        try? FileManager.default.removeItem(atPath: temp.path)
        let v = try await fs.volumeInfo(for: storage)
        #expect(v.totalCapacity == 256_000_000_000 && v.availableCapacity == 100_000_000_000)

        fs.close()
        let finalLog = try tmp.read("log")
        #expect(!fs.isSessionRunning || finalLog.hasSuffix("quit  \n"))
    }

    /// Nazwy z telefonu trafiają do ścieżek lokalnych i do poleceń pomocnika — niebezpieczne są
    /// pomijane; zamknięcie telefonu przerywa trwające pobieranie zamiast na nie czekać.
    @Test func mtpUnsafeNamesAndCloseDuringDownload() async throws {
        let tmp = try TempDir()
        let helper = try fakeHelper(tmp)
        FileManager.default.createFile(atPath: tmp.url.path + "/allowed", contents: Data())
        let fs = try MTPDeviceFS(device: DeviceInfo(id: "0", kind: .android, name: "Samsung"), helperPath: helper)
        defer { fs.close() }
        let other = fs.root.appending("Pamięć wewnętrzna").appending("Inne")
        #expect(try await fs.list(other, options: ListOptions()).map(\.name) == ["ok.jpg", "wolny.mp4"])

        let target = tmp.path
        let download = Task.detached { try fs.extract([other.appending("wolny.mp4")], toTemporaryIn: target, isCancelled: { false }) }
        // Pobieranie trwa (pomocnik dostał `get`) — warunek z terminem zamiast stałego opóźnienia.
        let deadline = ContinuousClock.now + .seconds(15)
        while (try? tmp.read("log"))?.contains("get 34") != true, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let start = ContinuousClock.now
        fs.close()
        // Luźny limit: pomocnik „pobiera” 10 s, zamknięcie nie może na to czekać.
        #expect(ContinuousClock.now - start < .seconds(8))
        do {
            _ = try await download.value
            Issue.record("zamknięcie telefonu powinno przerwać pobieranie")
        } catch VFSError.cancelled {
        } catch {
            Issue.record("oczekiwano anulowania, jest: \(error)")
        }
        #expect(!(try tmp.read("log")).contains("get 99"))
    }

    /// Protokół pomocnika MTP jest wierszowy: lokalna ścieżka docelowa ze znakiem nowej linii dopisałaby
    /// polecenie `get` z dowolną ścieżką — polecenie ze znakami sterującymi jest odrzucane przed wysłaniem.
    @Test func mtpRequestRejectsControlCharacters() async throws {
        #expect(throws: VFSError.self) { try MTPHelper.validate("get 21 /tmp/a\nget 99 /tmp/zle") }
        #expect(throws: VFSError.self) { try MTPHelper.validate("get 21 /tmp/a\r") }
        try MTPHelper.validate("get 21 /tmp/zażółć gęślą.jpg")

        let tmp = try TempDir()
        let helper = try fakeHelper(tmp)
        FileManager.default.createFile(atPath: tmp.url.path + "/allowed", contents: Data())
        let fs = try MTPDeviceFS(device: DeviceInfo(id: "0", kind: .android, name: "Samsung"), helperPath: helper)
        defer { fs.close() }
        let dcim = fs.root.appending("Pamięć wewnętrzna").appending("DCIM")
        _ = try await fs.list(dcim, options: ListOptions())
        let target = try tmp.dir("cel\nget 99 \(tmp.url.path)/zle")
        #expect(throws: VFSError.self) { _ = try fs.extract([dcim.appending("IMG_1.jpg")], toTemporaryIn: target, isCancelled: { false }) }
        #expect(!(try tmp.read("log")).contains("get 99") && !tmp.exists("zle"))
        // Sesja nadal działa.
        #expect(try await fs.list(dcim, options: ListOptions()).map(\.name) == ["Camera", "IMG_1.jpg"])
    }

    /// iPhone: podgląd folderu nie uruchamia `afcclient get -rf` (całe drzewo do katalogu tymczasowego).
    @Test func afcReadContentsRefusesFolders() async throws {
        let tmp = try TempDir()
        let tool = tmp.url.path + "/afcclient"
        let script = """
        #!/bin/sh
        echo "$*" >> "\(tmp.url.path)/args"
        echo 'drwxr-xr-x    1 mobile mobile        160 05 Mar 2026 10:11:12 100APPLE'
        """
        try Data(script.utf8).write(to: URL(filePath: tool))
        chmod(tool, 0o755)
        let fs = AFCDeviceFS(device: DeviceInfo(id: "U", kind: .iPhone, name: "i"), afcclient: tool)
        await #expect(throws: VFSError.self) { _ = try await fs.readContents(fs.root.appending("DCIM/100APPLE"), range: nil) }
        #expect(!(try tmp.read("args")).contains("get"))
    }

    /// Podgląd (treść pojedynczego pliku) nie pobiera całego folderu z telefonu.
    @Test func mtpReadContentsRefusesFolders() async throws {
        let tmp = try TempDir()
        let helper = try fakeHelper(tmp)
        FileManager.default.createFile(atPath: tmp.url.path + "/allowed", contents: Data())
        let fs = try MTPDeviceFS(device: DeviceInfo(id: "0", kind: .android, name: "Samsung"), helperPath: helper)
        defer { fs.close() }
        let storage = fs.root.appending("Pamięć wewnętrzna")
        await #expect(throws: VFSError.self) { _ = try await fs.readContents(storage.appending("DCIM"), range: nil) }
        await #expect(throws: VFSError.self) { _ = try await fs.readContents(storage, range: nil) }
        #expect(!(try tmp.read("log")).contains("get "), "nic nie pobrano")
        let data = try await fs.readContents(storage.appending("notatka ąę.txt"), range: nil)
        #expect(String(decoding: data, as: UTF8.self) == "plik-11")
    }

    @Test func toolRunnerTimeout() throws {
        let start = ContinuousClock.now
        #expect(throws: VFSError.self) { _ = try ToolRunner.run("/bin/sleep", ["30"], timeout: 0.5) }
        #expect(ContinuousClock.now - start < .seconds(15), "limit czasu, a nie koniec `sleep 30`")
        #expect(try ToolRunner.run("/bin/echo", ["zażółć"]).output == "zażółć\n")
    }

    @Test func noDevicesConnectedIsHandled() {
        #expect(DeviceDetector.iPhones(toolsDirectory: "/nonexistent").isEmpty)
        #expect(DeviceDetector.androids(helper: "/nonexistent").isEmpty)
    }
}
