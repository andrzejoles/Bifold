import Foundation
import Testing
@testable import BifoldCore
@testable import BifoldWorkspace

/// SCP: pobieranie i wysyłanie nie niszczą danych (dowiązania, błędy listingu, przerwane nadpisanie,
/// błąd jednego pliku) oraz wspólne połączenie główne kilku aliasów jednego serwera. Każdy Workspace testów
/// ma własną usługę Pęku kluczy (`.tests-<uuid>`), więc aliasy mogą się powtarzać między zestawami.
@MainActor @Suite(.serialized, .enabled(if: sshdAvailable)) struct ScpSafetyTests {
    func setup(_ sshd: TestSSHD, _ connections: RemoteConnection...) async throws -> (TempDir, Workspace) {
        let tmp = try TempDir()
        try tmp.dir("L")
        try tmp.dir("R")
        let (ws, _) = try await makeWorkspace(tmp, left: "L", right: "R")
        ws.remotes.sshConfigFile = sshd.clientConfig
        ws.remotes.sshKnownHostsFile = sshd.knownHosts
        for c in connections { try ws.remotes.save(c, secret: TestSSHD.passphrase) }
        return (tmp, ws)
    }

    func scp(_ ws: Workspace, _ alias: String) async throws -> ScpFS {
        try #require(try await ws.remotes.provider(alias) as? ScpFS)
    }

    func upload(_ fs: ScpFS, _ sources: [VFSPath], to destination: VFSPath, conflict: ConflictResolution = .skip,
                control: JobControl = JobControl()) async throws -> [String] {
        let job = ScpUpload(fs: fs, sources: sources, destination: destination, delegate: PolicyTransferDelegate(conflict: conflict))
        return try await runBlocking { try job.run(control: control) { _ in } }
    }

    /// Wrogi serwer: dowiązanie `aſ -> ../poza/plik` (APFS: „aſ” = „as”), potem plik `as` — `scp`
    /// zapisujący wprost pod nazwą poszedłby za dowiązaniem. Nazwa zajęta wcześniej przez kolizję
    /// („Readme (2)”) nie jest nadpisywana prawdziwym plikiem o tej nazwie.
    @Test func downloadNeverWritesThroughLinksOrOverExistingNames() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("as", "z serwera")
        try sshd.root.file("Readme (2)", "prawdziwy")
        let fs = try await scp(ws, "aix")
        try tmp.file("poza/plik", "ważne")
        try tmp.file("kat/Readme (2)", "kolizja")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.path + "/kat/aſ", withDestinationPath: "../poza/plik")

        let entries = try fs.entriesSync(fs.root)
        for name in ["as", "Readme (2)"] {
            let entry = try #require(entries.first { $0.item.name == name })
            try fs.fetch(entry, to: tmp.path.appending("kat").appending(name), topLevel: false, isCancelled: { false }, isPaused: { false }) { _ in }
        }
        #expect(try tmp.read("poza/plik") == "ważne", "plik poza katalogiem docelowym nietknięty")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tmp.url.path + "/kat/aſ") == "../poza/plik")
        #expect(try tmp.read("kat/as (2)") == "z serwera")
        #expect(try tmp.read("kat/Readme (2)") == "kolizja")
        #expect(try tmp.read("kat/Readme (2) (2)") == "prawdziwy")
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path + "/kat")
        #expect(!left.contains { $0.hasPrefix(".bifold-part-") }, "bez plików tymczasowych")
    }

    /// Wybór nazwy rozstrzyga system plików (także bez serwera): `RENAME_EXCL` nie idzie za dowiązaniem.
    @Test func exclusivePlacementSkipsLinksAndFoldedNames() throws {
        let tmp = try TempDir()
        try tmp.file("poza/plik", "ważne")
        try tmp.dir("kat")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.path + "/kat/bς", withDestinationPath: "../poza/plik")
        let part = try tmp.file("kat/.bifold-part-test", "nowy")
        let placed = try ScpFS.storeDownloaded(part, as: tmp.path.appending("kat/bσ"))
        #expect(placed.name == "bσ (2)")
        #expect(try tmp.read("kat/bσ (2)") == "nowy")
        #expect(try tmp.read("poza/plik") == "ważne")
        #expect(!tmp.exists("kat/.bifold-part-test"))
    }

    /// Błąd `cd`/`ls` nie wygląda jak pusty katalog: brak katalogu → „nie znaleziono”, pobranie drzewa
    /// z podkatalogiem bez praw → błąd (a nie po cichu pusty katalog, po którym „usuń” gubi dane).
    @Test func listingErrorsAreNotEmptyDirectories() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        let fs = try await scp(ws, "aix")
        #expect(throws: VFSError.notFound(fs.root.appending("brak"))) { _ = try fs.listSync(fs.root.appending("brak")) }

        try sshd.root.file("drzewo/a.txt", "a")
        try sshd.root.file("drzewo/zamknięty/b.txt", "b")
        let locked = sshd.root.url.path + "/drzewo/zamknięty"
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }
        #expect(throws: (any Error).self) {
            _ = try fs.extract([fs.root.appending("drzewo")], toTemporaryIn: tmp.path.appending("R"), isCancelled: { false })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path + "/R").isEmpty, "katalog tymczasowy usunięty")
    }

    /// Katalog docelowy, którego nie da się wylistować (prawa `-wx`): błąd tego katalogu, a istniejący
    /// plik nie jest nadpisany bez pytania jak „nowy”.
    @Test func uploadIntoUnlistableDirectoryReportsError() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("kat/a.txt", "stary")
        try tmp.file("L/kat/a.txt", "nowy")
        let dir = sshd.root.url.path + "/kat"
        chmod(dir, 0o300)
        defer { chmod(dir, 0o755) }
        let fs = try await scp(ws, "aix")
        let errors = try await upload(fs, [tmp.path.appending("L/kat")], to: fs.root)
        chmod(dir, 0o755)
        #expect(errors.count == 1 && errors[0].hasPrefix("kat:"), "\(errors)")
        #expect(try sshd.root.read("kat/a.txt") == "stary")
    }

    /// Anulowane „Nadpisz”: istniejący plik zostaje w całości (bez mieszanki bajtów i bez `rm -f`),
    /// plik tymczasowy znika.
    @Test func cancelledOverwriteKeepsOriginal() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("duzy.bin", "oryginał")
        let original = try FileManager.default.attributesOfItem(atPath: sshd.root.url.path + "/duzy.bin")[.size] as? Int
        // Duży plik rzadki (szybko tworzony, wysyłany dość długo, żeby zdążyć anulować).
        let big = tmp.url.path + "/L/duzy.bin"
        FileManager.default.createFile(atPath: big, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(filePath: big))
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        let fs = try await scp(ws, "aix")
        let control = JobControl()
        let job = ScpUpload(fs: fs, sources: [.local(big)], destination: fs.root, delegate: PolicyTransferDelegate(conflict: .overwrite))
        let running = Task.detached { try job.run(control: control) { _ in } }
        let root = sshd.root.url.path
        // Wysyłanie trwa: na serwerze rośnie plik tymczasowy (albo — błędnie — sam plik docelowy).
        let started = await eventually {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            let sizes = names.filter { $0 != "duzy.bin" }.compactMap { try? FileManager.default.attributesOfItem(atPath: root + "/" + $0)[.size] as? Int }
            let target = try? FileManager.default.attributesOfItem(atPath: root + "/duzy.bin")[.size] as? Int
            return sizes.contains { $0 > 0 } || target != original
        }
        #expect(started)
        control.cancel()
        await #expect(throws: VFSError.cancelled) { _ = try await running.value }
        #expect(try sshd.root.read("duzy.bin") == "oryginał")
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: root)) == ["duzy.bin"] }, "plik tymczasowy usunięty")
    }

    /// Serwer w ISO-8859-2: „€” nie ma w kodowaniu — błąd tego pliku (ze ścieżką względną), reszta drzewa wysłana.
    @Test func oneBadNameDoesNotStopTheTree() async throws {
        let sshd = try TestSSHD()
        var c = sshd.connection("latin2")
        c.nameEncoding = .latin2
        let (tmp, ws) = try await setup(sshd, c)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("latin2") }
        try tmp.file("L/paczka/a€.txt", "euro")
        try tmp.file("L/paczka/b.txt", "b")
        let fs = try await scp(ws, "latin2")
        let errors = try await upload(fs, [tmp.path.appending("L/paczka")], to: fs.root)
        #expect(errors.count == 1 && errors[0].hasPrefix("paczka/a€.txt:"), "\(errors)")
        #expect(try sshd.root.read("paczka/b.txt") == "b")
    }

    /// Dwa aliasy jednego serwera dzielą połączenie główne: rozłączenie B nie kończy terminala A,
    /// a agent nie rozłącza B, gdy A ma terminal.
    @Test func aliasesOfOneServerShareMasterSafely() async throws {
        let sshd = try TestSSHD()
        let a = sshd.connection("aix-a"), b = sshd.connection("aix-b")
        let (tmp, ws) = try await setup(sshd, a, b)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix-a"); try? ws.remotes.keychain.delete("aix-b") }
        try await ws.invoke("remote.open", CommandArguments(["alias": "aix-b", "terminal": false]))
        try await ws.invoke("remote.terminal", CommandArguments(["alias": "aix-a"]))
        #expect(ws.right.tabs.contains { $0.terminal?.alias == "aix-a" })
        #expect(ws.remotes.aliasesSharingSession(with: "aix-b") == ["aix-a", "aix-b"])

        let gate = AllowAllGate()
        ws.agentGate = gate
        defer { withExtendedLifetime(gate) {} }
        await #expect(throws: (any Error).self) {
            try await ws.invoke("remote.disconnect", CommandArguments(["alias": "aix-b"]), invoker: .agent(sessionID: "t", agentName: "t"))
        }
        #expect(ws.remotes.connected.contains("aix-b"))

        try await ws.invoke("remote.disconnect", CommandArguments(["alias": "aix-b"]))
        #expect(!ws.remotes.connected.contains("aix-b"))
        #expect(try ws.remotes.sshSession(a).isConnected, "połączenie główne terminala A nadal działa")
        #expect(ws.right.tabs.contains { $0.terminal?.alias == "aix-a" })
    }

    /// „Rozłącz” w trakcie łączenia: dostawca nie jest rejestrowany, połączenie główne nie zostaje.
    @Test func disconnectWhileConnectingCancels() async throws {
        let sshd = try TestSSHD()
        let c = sshd.connection("aix")
        let (tmp, ws) = try await setup(sshd, c)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        let opening = Task { @MainActor in try await ws.remotes.provider("aix") }
        while ws.remotes.connecting["aix"] == nil { await Task.yield() }
        await ws.remotes.disconnect("aix")
        await #expect(throws: (any Error).self) { _ = try await opening.value }
        #expect(!ws.remotes.connected.contains("aix"))
        #expect((try? ws.providers.provider(for: RemoteFS.providerID("aix"))) == nil)
        #expect(!(try ws.remotes.sshSession(c).isConnected), "połączenie główne zamknięte")
    }

    /// Zmiana połączenia: stary dostawca wyrejestrowany (karta nie połączy się nim ze starym hostem).
    @Test func savingConnectionUnregistersOldProvider() async throws {
        let sshd = try TestSSHD()
        try sshd.root.dir("pod")
        var c = sshd.connection("aix")
        let (tmp, ws) = try await setup(sshd, c)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        let old = try await scp(ws, "aix")
        c.path = sshd.root.url.path + "/pod"
        try ws.remotes.save(c, secret: TestSSHD.passphrase)
        #expect((try? ws.providers.provider(for: RemoteFS.providerID("aix"))) == nil)
        #expect(!old.session.isConnected)
        let new = try await scp(ws, "aix")
        #expect(new !== old && new.base.hasSuffix("/pod"))
    }

    // MARK: Nadpisywanie: dowiązania, niezgodny typ, zapis w miejscu

    /// Plik lokalny o treści `text` w katalogu testu.
    func localFile(_ tmp: TempDir, _ name: String, _ text: String) throws -> URL {
        try tmp.file("L/" + name, text)
        return tmp.url.appending(path: "L/" + name)
    }

    func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Edycja pliku otwartego przez dowiązanie: nowa treść trafia do pliku, na który wskazuje, a dowiązanie
    /// zostaje dowiązaniem (wcześniej `mv -f` zastępował je zwykłym plikiem, a prawdziwy plik się nie zmieniał).
    /// „Nadpisz” przy kopiowaniu zastępuje — jak lokalnie — samo dowiązanie, a jego cel zostaje bez zmian.
    @Test func uploadThroughSymlinkWritesTarget() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("real.txt", "stara")
        try FileManager.default.createSymbolicLink(atPath: sshd.root.url.path + "/link", withDestinationPath: "real.txt")
        let fs = try await scp(ws, "aix")
        try await fs.upload(try localFile(tmp, "edycja.txt", "nowa"), to: fs.root.appending("link"))
        #expect(try sshd.root.read("real.txt") == "nowa")
        #expect(isSymlink(sshd.root.url.path + "/link"), "dowiązanie zostało dowiązaniem")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sshd.root.url.path).sorted() == ["link", "real.txt"], "bez plików tymczasowych")

        // Kopiowanie z „Nadpisz”: dowiązanie zastąpione plikiem, cel nietknięty.
        try tmp.file("L/link", "z dysku")
        let errors = try await upload(fs, [tmp.path.appending("L/link")], to: fs.root, conflict: .overwrite)
        #expect(errors.isEmpty, "\(errors)")
        #expect(!isSymlink(sshd.root.url.path + "/link"))
        #expect(try sshd.root.read("link") == "z dysku")
        #expect(try sshd.root.read("real.txt") == "nowa")
    }

    /// „Nadpisz” katalogu (z zawartością) plikiem, anulowane w trakcie wysyłania: katalog na serwerze
    /// zostaje (wcześniej `rm -r -f` szedł przed wysłaniem), element tymczasowy znika. Bez anulowania —
    /// katalog zastąpiony plikiem, a plik zastąpiony katalogiem przez katalog tymczasowy.
    @Test func cancelledReplaceKeepsDirectory() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("duzy.bin/ważne.txt", "zawartość")
        let big = tmp.url.path + "/L/duzy.bin"
        FileManager.default.createFile(atPath: big, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(filePath: big))
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        let fs = try await scp(ws, "aix")
        let control = JobControl()
        let job = ScpUpload(fs: fs, sources: [.local(big)], destination: fs.root, delegate: PolicyTransferDelegate(conflict: .overwrite))
        let running = Task.detached { try job.run(control: control) { _ in } }
        let root = sshd.root.url.path
        // Wysyłanie trwa: na serwerze rośnie plik tymczasowy (albo — błędnie — katalog już zniknął).
        let started = await eventually {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            let sizes = names.filter { $0 != "duzy.bin" }.compactMap { try? FileManager.default.attributesOfItem(atPath: root + "/" + $0)[.size] as? Int }
            return sizes.contains { $0 > 0 } || !sshd.root.exists("duzy.bin/ważne.txt")
        }
        #expect(started)
        control.cancel()
        await #expect(throws: VFSError.cancelled) { _ = try await running.value }
        #expect(try sshd.root.read("duzy.bin/ważne.txt") == "zawartość", "katalog na serwerze nietknięty")
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: root)) == ["duzy.bin"] }, "plik tymczasowy usunięty")

        // Do końca: katalog → plik, potem plik → katalog (z podkatalogiem).
        try FileManager.default.removeItem(atPath: big)
        try tmp.file("L/duzy.bin", "plik")
        #expect(try await upload(fs, [.local(big)], to: fs.root, conflict: .overwrite).isEmpty)
        #expect(try sshd.root.read("duzy.bin") == "plik")
        try FileManager.default.removeItem(atPath: big)
        try tmp.file("L/duzy.bin/pod/a.txt", "a")
        #expect(try await upload(fs, [.local(big)], to: fs.root, conflict: .overwrite).isEmpty)
        #expect(try sshd.root.read("duzy.bin/pod/a.txt") == "a")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["duzy.bin"], "bez katalogu tymczasowego")
    }

    /// Katalog bez prawa zapisu (jak /etc) z zapisywalnym plikiem: zapis w miejscu — o tym decyduje
    /// `[ -w katalog ]` na serwerze, a nie angielski tekst błędu `scp` (AIX po polsku go nie wypisze).
    @Test func inPlaceWriteWhenDirectoryIsReadOnly() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("etc/konfig.conf", "stara")
        let dir = sshd.root.url.path + "/etc"
        chmod(dir, 0o555)
        defer { chmod(dir, 0o755) }
        let fs = try await scp(ws, "aix")
        #expect(try fs.isWritableDirectory(fs.root) && !(try fs.isWritableDirectory(fs.root.appending("etc"))))
        try await fs.upload(try localFile(tmp, "konfig.conf", "edycja"), to: fs.root.appending("etc/konfig.conf"))
        #expect(try sshd.root.read("etc/konfig.conf") == "edycja")
        try tmp.file("L/kopia/konfig.conf", "z kopii")
        let errors = try await upload(fs, [tmp.path.appending("L/kopia/konfig.conf")], to: fs.root.appending("etc"), conflict: .overwrite)
        #expect(errors.isEmpty, "\(errors)")
        #expect(try sshd.root.read("etc/konfig.conf") == "z kopii")
        // Nowy plik w takim katalogu to nadal błąd (nie ma czego zapisać w miejscu).
        try tmp.file("L/kopia/nowy.conf", "x")
        let refused = try await upload(fs, [tmp.path.appending("L/kopia/nowy.conf")], to: fs.root.appending("etc"))
        #expect(refused.count == 1 && !sshd.root.exists("etc/nowy.conf"), "\(refused)")
    }

    /// `mv -f` zawodzi, choć plik tymczasowy powstał (na serwerze np. katalog z bitem „sticky” i cudzy plik;
    /// tu katalog traci prawo zapisu po wysłaniu): zapis w miejscu z pliku tymczasowego. Pliku tymczasowego
    /// nie da się wtedy usunąć — błąd podaje jego nazwę, zamiast zostawić go bez śladu.
    @Test func failedRenameFallsBackInPlaceAndReportsLeftovers() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("kat/plik.txt", "stara")
        let dir = sshd.root.url.path + "/kat"
        defer { chmod(dir, 0o755) }
        let fs = try await scp(ws, "aix")
        fs.beforeCommit.withLock { $0 = { _ = chmod(dir, 0o555) } }
        defer { fs.beforeCommit.withLock { $0 = nil } }
        let local = try localFile(tmp, "plik.txt", "nowa")
        for (name, fallback) in [("plik.txt", true), ("nowy.txt", false)] {
            chmod(dir, 0o755)
            do {
                try fs.putFile(local.path, to: fs.root.appending("kat/" + name), inPlaceFallback: fallback, isCancelled: { false }, isPaused: { false })
                Issue.record("plik tymczasowy nie mógł zostać usunięty — oczekiwano błędu")
            } catch {
                let left = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("." + name + ".bifold-") }
                #expect(left.count == 1 && error.localizedDescription.contains(left[0]), "\(left) \(error.localizedDescription)")
            }
        }
        #expect(try sshd.root.read("kat/plik.txt") == "nowa", "zapis w miejscu z pliku tymczasowego")
        #expect(!sshd.root.exists("kat/nowy.txt"))
    }

    // MARK: Pobieranie pojedynczego pliku

    /// `remote.read` (agent, poziom Odczyt) i podgląd na dowiązaniu do katalogu: odmowa zamiast pobierania
    /// całego drzewa (`link -> /` — cały serwer) do katalogu tymczasowego.
    @Test func readRefusesLinksToDirectories() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("drzewo/a.txt", "a")
        let name = "link-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createSymbolicLink(atPath: sshd.root.url.path + "/" + name, withDestinationPath: "drzewo")
        let gate = AllowAllGate()
        ws.agentGate = gate
        defer { withExtendedLifetime(gate) {} }
        do {
            _ = try await ws.invoke("remote.read", CommandArguments(["alias": "aix", "path": .string("/" + name)]), invoker: .agent(sessionID: "t", agentName: "t"))
            Issue.record("odczyt dowiązania do katalogu powinien być odrzucony")
        } catch CommandError.invalidArgument(let key, _) {
            #expect(key == "path")
        }
        let fs = try await scp(ws, "aix")
        await #expect(throws: VFSError.self) { _ = try await fs.readContents(fs.root.appending(name), range: nil) }
        await #expect(throws: VFSError.self) { _ = try await fs.download(fs.root.appending("drzewo")) }
        let temps = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix(".bifold-scp-") }
        #expect(!temps.contains { FileManager.default.fileExists(atPath: NSTemporaryDirectory() + $0 + "/" + name) }, "nic nie pobrano")
        // Zwykły plik nadal się czyta (wynik dla agenta jako dane niezaufane).
        let read = try await ws.invoke("remote.read", CommandArguments(["alias": "aix", "path": "/drzewo/a.txt"]), invoker: .agent(sessionID: "t", agentName: "t"))
        #expect(read.value?["untrusted"] == true && read.value?["content"]?["text"] == "a")
    }

    // MARK: Błędy `cd` w innych powłokach (dash; ksh88 pisze podobnie nieznane komunikaty)

    @Test(arguments: ["/bin/dash", "/bin/ksh"])
    func listingErrorsInOtherShells(shell: String) async throws {
        try #require(FileManager.default.isExecutableFile(atPath: shell))
        let sshd = try TestSSHD(shell: shell)
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("plik.txt", "p")
        try sshd.root.file("zamknięty/x.txt", "x")
        let locked = sshd.root.url.path + "/zamknięty"
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }
        let fs = try await scp(ws, "aix")
        #expect(throws: VFSError.notFound(fs.root.appending("brak"))) { _ = try fs.listSync(fs.root.appending("brak")) }
        #expect(throws: VFSError.permissionDenied(fs.root.appending("zamknięty"))) { _ = try fs.listSync(fs.root.appending("zamknięty")) }
        #expect(throws: VFSError.notADirectory(fs.root.appending("plik.txt"))) { _ = try fs.listSync(fs.root.appending("plik.txt")) }
        // Polecenia zapisu w tej powłoce: przez dowiązanie i zastąpienie katalogu.
        try FileManager.default.createSymbolicLink(atPath: sshd.root.url.path + "/link", withDestinationPath: "plik.txt")
        try await fs.upload(try localFile(tmp, "e.txt", "nowa"), to: fs.root.appending("link"))
        #expect(try sshd.root.read("plik.txt") == "nowa" && isSymlink(sshd.root.url.path + "/link"))
        try sshd.root.file("kat/a.txt", "a")
        try tmp.file("L/kat", "plik")
        #expect(try await upload(fs, [tmp.path.appending("L/kat")], to: fs.root, conflict: .overwrite).isEmpty)
        #expect(try sshd.root.read("kat") == "plik")
    }

    // MARK: Rozłączenie i zmiana połączenia

    /// Po „Rozłącz” zadanie trzymające starą sesję nie zestawia po cichu nowego połączenia głównego
    /// (`ssh -N -f` z ControlPersist, którego nikt by nie zamknął) — kończy się anulowaniem.
    @Test func disconnectedSessionDoesNotReconnect() async throws {
        let sshd = try TestSSHD()
        let (tmp, ws) = try await setup(sshd, sshd.connection("aix"))
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try sshd.root.file("a.txt", "a")
        let fs = try await scp(ws, "aix")
        await ws.remotes.disconnect("aix")
        #expect(fs.session.isClosed)
        #expect(throws: VFSError.cancelled) { _ = try fs.listSync(fs.root) }
        let local = try localFile(tmp, "b.txt", "b")
        await #expect(throws: VFSError.cancelled) { _ = try await upload(fs, [.local(local.path)], to: fs.root) }
        #expect(!FileManager.default.fileExists(atPath: fs.session.controlPath), "bez nowego połączenia głównego")
        #expect(!sshd.root.exists("b.txt"))
    }

    /// Zapis albo usunięcie połączenia w trakcie łączenia: dostawca ze starymi danymi (albo usuniętego
    /// połączenia) nie jest rejestrowany.
    @Test func saveOrRemoveWhileConnectingCancels() async throws {
        let sshd = try TestSSHD()
        try sshd.root.dir("pod")
        var c = sshd.connection("aix")
        let (tmp, ws) = try await setup(sshd, c)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        let opening = Task { @MainActor in try await ws.remotes.provider("aix") }
        while ws.remotes.connecting["aix"] == nil { await Task.yield() }
        c.path = sshd.root.url.path + "/pod"
        try ws.remotes.save(c, secret: TestSSHD.passphrase)
        await #expect(throws: (any Error).self) { _ = try await opening.value }
        #expect((try? ws.providers.provider(for: RemoteFS.providerID("aix"))) == nil, "stary dostawca niezarejestrowany")
        let fresh = try await scp(ws, "aix")
        #expect(fresh.base.hasSuffix("/pod"))

        await ws.remotes.disconnect("aix")
        let again = Task { @MainActor in try await ws.remotes.provider("aix") }
        while ws.remotes.connecting["aix"] == nil { await Task.yield() }
        try ws.remotes.remove("aix")
        await #expect(throws: (any Error).self) { _ = try await again.value }
        #expect((try? ws.providers.provider(for: RemoteFS.providerID("aix"))) == nil && !ws.remotes.connected.contains("aix"))
    }

    /// Zmiana połączenia (np. hasła) przy otwartej karcie: karta nie zostaje bez dostawcy — połączenie
    /// z nowymi danymi wraca w tle, odświeżenie działa.
    @Test func savingWithOpenTabReconnects() async throws {
        let sshd = try TestSSHD()
        try sshd.root.file("a.txt", "a")
        let c = sshd.connection("aix")
        let (tmp, ws) = try await setup(sshd, c)
        defer { withExtendedLifetime(tmp) {} }  // katalog testu żyje do końca (zapis połączeń by go odtworzył)
        defer { ws.remotes.stop(); try? ws.remotes.keychain.delete("aix") }
        try await ws.invoke("remote.open", CommandArguments(["alias": "aix", "terminal": false]))
        let old = try await scp(ws, "aix")
        #expect(ws.remotes.isKnown(alias: "aix") && !ws.remotes.isKnown(alias: "brak"))
        try ws.remotes.save(c, secret: TestSSHD.passphrase)
        #expect(old.session.isClosed)
        #expect(await eventually { (try? ws.providers.provider(for: RemoteFS.providerID("aix"))) != nil }, "połączenie wróciło")
        try sshd.root.file("b.txt", "b")
        try await ws.invoke("panel.refresh")
        #expect(ws.left.activeTab.items.contains { $0.name == "b.txt" })
    }
}
