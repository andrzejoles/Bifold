# Bifold — architektura

Dokument opisuje moduły, główne protokoły, model stanu, kolejkę i dziennik operacji, model
uprawnień agenta oraz przepływ wywołania od CLI agenta przez most MCP do aplikacji.
Wymagania źródłowe: [`PROMPT.md`](PROMPT.md). Decyzje i ich uzasadnienia: [`DECISIONS.md`](DECISIONS.md).

## 1. Układ repozytorium

```
Bifold/
├── project.yml                 # definicja projektu Xcode (XcodeGen) — źródło prawdy
├── Bifold.xcodeproj            # wygenerowany z project.yml (commitowany dla wygody)
├── Makefile                    # bootstrap, generate, build, release, test, run, installer, version
├── Config/
│   ├── Brand.xcconfig          # NAZWA APLIKACJI I BUNDLE ID — jedyne miejsce
│   └── Bifold.entitlements     # bez sandboxa
├── App/                        # cel Bifold.app (AppKit, SwiftUI tylko w ustawieniach/dialogach)
│   ├── Info.plist
│   ├── Sources/
│   ├── Resources/              # Localizable.xcstrings, InfoPlist.xcstrings, Assets
│   └── Helper/                 # (Etap 7) Info.plist pomocnika administratora (plik demona generowany przy budowaniu z Brand.xcconfig)
├── Packages/BifoldKit/         # cała logika jako pakiet SPM, testowalny bez interfejsu
│   ├── Package.swift
│   ├── Sources/
│   │   ├── BifoldCore/         # VFS, LocalFS, operacje, kolejka, dziennik, maski, reguły kolorów
│   │   ├── BifoldWorkspace/    # model stanu aplikacji, rejestr komend, komendy, skróty
│   │   ├── BifoldAgent/        # (Etap 2) polityka uprawnień, sesje, serwer gniazda, narzędzia MCP
│   │   ├── BifoldBridgeKit/    # (Etap 2) logika mostu: stdio MCP <-> gniazdo Unix
│   │   ├── bifold-mcp/         # (Etap 2) plik wykonywalny mostu (cienka powłoka na BifoldBridgeKit)
│   │   ├── BifoldHelperKit/    # (Etap 7) protokół i walidacja operacji pomocnika administratora
│   │   └── bifold-helper/      # (Etap 7) demon XPC (LaunchDaemon przez SMAppService)
│   └── Tests/
├── Tools/bifold-mtp/           # (Etap 7) pomocnik MTP w C (libmtp z Homebrew), osobny proces
├── ThirdParty/HexFiend/        # submoduł git (HexFiend 2.18.1), budowany skryptem
├── scripts/                    # budowanie (HexFiend, bifold-mtp), wersja, tłumaczenia, instalatory, podpis, wydanie
└── docs/
```

Zależności między modułami (strzałka = „zależy od”):

```
Bifold.app ──► BifoldWorkspace ──► BifoldCore
     │               ▲
     └──► BifoldAgent┘ ──► MCP (swift-sdk), BifoldBridgeKit      bifold-mcp ──► BifoldBridgeKit (tylko Foundation)
     └──► BifoldHelperKit, SwiftTerm, Sparkle, HexFiend.framework, QuickLookUI
                                                    bifold-helper ──► BifoldHelperKit
```

`BifoldCore` i `BifoldWorkspace` nie importują AppKit. Wszystko, co wymaga interfejsu
(pytania o nazwę, okno konfliktu, Quick Look, otwarcie w edytorze), przechodzi przez protokoły
usług (`UIServices`, `ConflictResolver`), które implementuje cel aplikacji, a w testach — atrapy.

## 2. Wirtualny system plików

```swift
public struct VFSPath: Hashable, Sendable, Codable {   // adres w dowolnym systemie plików
    public var provider: ProviderID   // "local", "archive:<id>", "remote:<alias>", "device:<id>"
    public var path: String           // ścieżka POSIX w obrębie dostawcy, zawsze absolutna
}

public struct FileItem: Hashable, Sendable, Identifiable {
    public var id: VFSPath
    public var name: String
    public var kind: FileKind          // .file, .directory, .symlink, .package, .other
    public var size: Int64             // dla katalogów: -1 dopóki nie policzono
    public var modified, created: Date?
    public var permissions: UInt16     // bity POSIX
    public var owner, group: UInt32
    public var flags: FileFlags        // hidden, locked/immutable, ...
    public var tags: [String]          // tagi Findera (ładowane leniwie)
}

public protocol FileSystemProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }   // read, write, rename, trash, watch, xattr, tags...
    func list(_ dir: VFSPath, options: ListOptions) async throws -> [FileItem]
    func item(at path: VFSPath) async throws -> FileItem
    func readContents(_ path: VFSPath, range: Range<Int64>?) async throws -> Data
    func watch(_ dir: VFSPath) -> AsyncStream<DirectoryChange>
    // operacje modyfikujące (domyślnie rzucają .unsupported)
    func createDirectory(_ path: VFSPath) async throws
    func createFile(_ path: VFSPath) async throws
    func rename(_ path: VFSPath, to newName: String) async throws -> VFSPath
    func trash(_ path: VFSPath) async throws -> VFSPath?      // nowa ścieżka w Koszu (do cofania)
    func delete(_ path: VFSPath) async throws
    func setAttributes(_ path: VFSPath, _ attrs: AttributeChange) async throws
    func volumeInfo(for path: VFSPath) async throws -> VolumeInfo
}
```

- `LocalFS` (Etap 1): listowanie przez `getattrlistbulk(2)` z jednym przebiegiem po katalogu
  (zapasowo `FileManager` z prefetchem kluczy), obserwowanie przez FSEvents, kopiowanie przez
  `copyfile(3)` z `COPYFILE_ALL | COPYFILE_CLONE` i callbackiem postępu (pauza, limit prędkości,
  anulowanie działają wewnątrz callbacku), Kosz przez `FileManager.trashItem(resultingItemURL:)`.
- `ArchiveFS` (Etap 4): `7zz l -slt` → drzewo w pamięci (klucze NFC), odczyt `7zz e -so`,
  kopiowanie przez rozpakowanie do katalogu tymczasowego (`ExtractingProvider`).
- `RemoteFS` (Etap 5): `rclone rcd` na gnieździe Unix z konfiguracją w pamięci; `operations/*`,
  przesyłanie `RcloneTransfer` (zadania `_async`, postęp `core/stats`, `job/stop`).
- `AFCDeviceFS` / `MTPDeviceFS` (Etap 7): `afcclient` / pomocnik `bifold-mtp` (D45), tylko do odczytu.
- `SearchResultsFS` (Etap 3): wyniki wyszukiwania jako „katalog” z prawdziwymi ścieżkami.
- `LocalFS` odrzuca każdą ścieżkę innego dostawcy (`/a/b` z archiwum to nie `/a/b` na dysku).
- `ProviderRegistry` rozwiązuje `ProviderID` → dostawcę. Panele, operacje, wyszukiwanie i API
  agenta używają wyłącznie protokołu.

Operacje między dostawcami (np. archiwum → lokalny) realizuje kolejka: jeśli dostawca źródłowy
i docelowy to ten sam `LocalFS`, używa natywnej ścieżki (`copyfile`, `rename`); w przeciwnym razie
strumieniowo `readContents` → `writeContents`.

## 3. Model stanu aplikacji

Jeden obiekt `@MainActor @Observable final class Workspace` (moduł `BifoldWorkspace`):

```
Workspace
├── panels: [PanelSide.left: Panel, .right: Panel]
├── activeSide: PanelSide
├── settings: Settings (skróty, reguły kolorów, edytor, ścieżki narzędzi, motyw, limity agenta)
├── operations: OperationQueue (zadania w tle)
├── journal: OperationJournal
└── commandRegistry: CommandRegistry

Panel
├── tabs: [Tab], activeTabIndex
└── showsTree, showsPreview

Tab (zapisywana między uruchomieniami: path, viewMode, sort)
├── path: VFSPath, history (wstecz/dalej w obrębie karty)
├── viewMode: .details | .brief | .thumbnails | .columns
├── sort: SortDescriptor (kolumna, kierunek, katalogi najpierw)
├── listing: DirectoryListing        # wszystkie elementy katalogu (z FSEvents)
├── quickFilter: String?             # filtr panelu
├── visibleItems: [FileItem]         # listing ∘ filtr ∘ sortowanie — liczone w tle
├── cursor: VFSPath?                 # wiersz z fokusem
├── selection: Set<VFSPath>          # zaznaczenie (Spacja/Shift/maska)
└── directorySizes: [VFSPath: Int64] # policzone rozmiary katalogów
```

Interfejs tylko czyta model (`withObservationTracking`) i wywołuje komendy. Sortowanie i
filtrowanie 100 000 elementów wykonuje `ListingProcessor` (actor) poza wątkiem głównym; wynik
podmienia `visibleItems` jednym przypisaniem. Stan kart serializuje `SessionStore`
(`~/Library/Application Support/Bifold/session.json`).

## 4. Rejestr komend

```swift
public enum AgentAccess: Int, Comparable, Codable, Sendable {
    case none = 0, read = 1, approval = 2, full = 3   // Brak, Odczyt, Za zgodą, Pełny
}

public struct CommandDescriptor: Sendable {
    public let id: CommandID              // np. "file.copy", "panel.switch", "tab.new"
    public let title: String.LocalizationValue
    public let category: CommandCategory
    public let defaultShortcuts: [ShortcutProfile: [KeyChord]]
    public let parameters: [CommandParameter]   // nazwa, typ, wymagany, opis (→ schemat MCP)
    public let agentAccess: AgentAccess
    public let effects: CommandEffects    // .none, .navigation, .modifiesFiles, .externalApp...
}

public protocol Command: Sendable {
    static var descriptor: CommandDescriptor { get }
    @MainActor func preview(_ args: CommandArguments, in ctx: CommandContext) async throws -> EffectPreview
    @MainActor func run(_ args: CommandArguments, in ctx: CommandContext) async throws -> CommandResult
}
```

- `CommandContext` daje dostęp do `Workspace`, `UIServices` i informacji o wywołującym
  (`Invoker.user(.keyboard|.menu|.palette|.commandLine)` albo `Invoker.agent(sessionID)`).
- `preview` liczy skutki na sucho (lista operacji, ścieżki, liczba plików, rozmiar, konflikty) —
  używa go okno zatwierdzania agenta i potwierdzenia dla użytkownika (np. trwałe usuwanie).
- Klawiatura (`Keymap`: skróty jako odpowiedniki klawiszowe menu i `PanelViewController.handleKey`),
  menu (budowane z rejestru), paleta komend (Cmd+Shift+P)
  i API agenta wywołują `CommandRegistry.invoke(id, args, invoker)` — jedną funkcję.
- Profile skrótów: `totalCommander` (F-klawisze) i `command` (Cmd-owe zamienniki). Użytkownik
  nadpisuje pojedyncze skróty; zapis w `keymap.json`.

## 5. Kolejka operacji

`OperationQueue` (actor) przechowuje `FileJob` (kopiowanie, przenoszenie, Kosz, trwałe usuwanie,
później pakowanie i synchronizacja). Każde zadanie:

1. **Planowanie** — rozwinięcie drzewa źródeł (`JobPlan`: lista elementów, łączny rozmiar,
   konflikty). Ten sam kod liczy podgląd „na sucho” (`preview`).
2. **Wykonanie** — w tle, element po elemencie, z `JobProgress` (bajty, pliki, prędkość, ETA).
3. **Sterowanie** — `pause()`, `resume()`, `cancel()`, `setSpeedLimit(bytesPerSecond)`.
   Pauza i limit działają wewnątrz callbacku `copyfile`, więc obejmują też duże pojedyncze pliki.
4. **Konflikty** — `ConflictResolver` (UI) zwraca `.overwrite | .skip | .rename | .overwriteOlder`
   z flagą „dla wszystkich”; decyzja „dla wszystkich” jest pamiętana w zadaniu.
5. **Dziennik** — po każdym ukończonym elemencie zadanie dopisuje wpis do `OperationJournal`.

Domyślnie zadania wykonują się sekwencyjnie (jedno aktywne), równolegle tylko między różnymi
woluminami — konfigurowalne.

## 6. Dziennik operacji i cofanie

`OperationJournal` zapisuje JSONL w `~/Library/Application Support/Bifold/journal/`:

```json
{"id":"…","batch":"…","time":"…","invoker":{"user":{}},"kind":"move",
 "from":"/a/x.txt","to":"/b/x.txt","fingerprint":{"size":12,"mtime":…,"inode":…},
 "inverse":{"kind":"move","from":"/b/x.txt","to":"/a/x.txt"}}
```

- Rodzaje: `move`, `rename`, `trash` (z nową ścieżką w Koszu), `create` (plik/katalog),
  `copy` (odwrotność: usuń kopię do Kosza), `setAttributes` / `setTags` (poprzednie wartości).
- Wpisy jednej komendy mają wspólny `batch`; „Cofnij” (Cmd+Z, `NSUndoManager`) cofa ostatni batch.
- Przed cofnięciem `UndoPlanner` sprawdza konflikty: plik docelowy zmieniony od czasu operacji
  (inny rozmiar/mtime/inode), ścieżka powrotna zajęta, element zniknął z Kosza. Konflikty trafiają
  do podglądu do zatwierdzenia.
- „Cofnij sesję agenta” (Etap 2) = wszystkie batche z `invoker.agent(sessionID)` w odwrotnej
  kolejności, z jednym wspólnym podglądem.

## 7. Model uprawnień agenta (Etap 2, przygotowany od Etapu 1)

Poziom komendy pochodzi z `CommandDescriptor.agentAccess` (macierz z sekcji 6 PROMPT.md).
Efektywny poziom wywołania:

```
efektywny = min( poziom_komendy,
                 poziom_sesji_dla_komendy (macierz sesji, domyślnie = poziom komendy),
                 min(poziom_zasobu(z) dla każdego zasobu z w wywołaniu) )
```

- `poziom_zasobu`: lokalny = pełny; ścieżka z listy zablokowanych = **brak** (wywołanie odrzucone
  i ścieżka ukryta w listingach); serwery (Etap 5): SFTP/WebDAV/SMB/chmury = odczyt, FTP = za zgodą;
  archiwum z hasłem = brak.
- Dla operacji zapisujących zasób z poziomem „odczyt” daje „brak” — stąd przykład z PROMPT.md:
  kopiowanie FTP → SFTP jest zabronione.
- `brak` → narzędzie niewidoczne (`tools/list`) albo błąd `permission_denied`;
  `read` → wykonanie, jeśli komenda nie ma efektu `.modifiesFiles`;
  `approval` → `preview` + okno zatwierdzania (asynchroniczne oczekiwanie na decyzję);
  `full` → wykonanie bez pytania, z wpisem w dzienniku (cofalne).

## 8. Przepływ wywołania agenta (Etap 2)

```
┌────────────┐ stdio (JSON-RPC MCP) ┌────────────┐ gniazdo Unix 0600 ┌──────────────────────────┐
│ CLI agenta │ ───────────────────► │ bifold-mcp │ ────────────────► │ Bifold.app: AgentServer  │
│ claude/... │ ◄─────────────────── │  (most)    │ ◄──────────────── │  ├ SessionAuthenticator  │
└────────────┘                      └────────────┘   ramki z długością│  ├ PeerVerifier          │
      ▲  env: BIFOLD_AGENT_TOKEN (dziedziczony przez most)            │  ├ AgentPolicy           │
      │                                                                │  ├ ToolCatalog → Command │
      └── uruchomiony przez AgentLauncher w SwiftTerm (PTY)            │  ├ ApprovalCenter (UI)   │
                                                                       │  └ AgentLog (JSONL)      │
                                                                       └──────────────────────────┘
```

1. Użytkownik wybiera agenta. `AgentLauncher` generuje 256-bitowy token (`SecRandomCopyBytes`),
   rejestruje sesję (`AgentSession`: id, agent, katalog, macierz uprawnień, PID procesu CLI),
   buduje konfigurację MCP tylko dla tej sesji i uruchamia CLI w PTY (SwiftTerm) z `BIFOLD_AGENT_TOKEN`
   w środowisku procesu (nigdy w argumentach — argumenty widać w `ps`).
2. CLI uruchamia `bifold-mcp` (stdio). Most łączy się z `agent.sock`, wysyła ramkę `hello`
   z tokenem i własnym PID, potem przekazuje komunikaty MCP bez interpretacji.
3. `AgentServer`: `getpeereid` (UID == UID aplikacji), `LOCAL_PEERPID` → łańcuch rodziców
   (`sysctl KERN_PROC_PID`) musi zawierać PID procesu CLI tej sesji; token porównany w stałym
   czasie; limit wywołań na minutę.
4. Serwer MCP (swift-sdk, transport po stronie aplikacji na gnieździe) obsługuje `tools/list`
   (tylko narzędzia z efektywnym poziomem > brak) i `tools/call` → `AgentPolicy` →
   `CommandRegistry.invoke(..., invoker: .agent(session))`.
5. Wyniki: dane z plików oznaczone jako niezaufane (`{"untrusted_content": …}` + adnotacja),
   ścieżki zablokowane odfiltrowane, rozmiar odczytu ograniczony.
6. Zamknięcie sesji (wyjście procesu CLI lub zamknięcie panelu) unieważnia token i rozłącza most.

### Konfiguracja MCP na sesję (ustalona z `--help` 2026-10-17)

| Agent | Serwer MCP tylko na sesję | Tryb ścisły |
|---|---|---|
| Claude Code | `--mcp-config <json> --strict-mcp-config` | `--tools ""` + `--allowedTools mcp__bifold__*` |
| Codex CLI | `-c mcp_servers.bifold.command="…" -c mcp_servers.bifold.env_vars=["BIFOLD_AGENT_TOKEN"]` | `--sandbox read-only` |
| Grok CLI | `GROK_CONFIG=<plik tymczasowy .toml>` (nakładka konfiguracji) z `[mcp_servers.bifold]` | `--sandbox read-only` + `--disallowed-tools` (powłoka i edycja) |
| Antigravity | brak opcji na sesję → `agy mcp add bifold <most>` jednorazowo, za zgodą | `--sandbox` |

### Narzędzia MCP

Narzędzia to widok na rejestr komend (`ToolCatalog`). Nazwy narzędzi i odpowiadające komendy:

| Narzędzie | Komenda | Poziom |
|---|---|---|
| `get_state` | `agent.state` | odczyt |
| `get_selection` | `agent.selection` | odczyt |
| `list_directory` | `agent.list` | odczyt |
| `file_info` | `agent.fileInfo` | odczyt |
| `read_file` | `agent.readFile` | odczyt |
| `dir_size` | `selection.calculateSizes` | odczyt |
| `navigate` | `panel.navigate` | pełny |
| `tab_open` / `tab_close` / `tab_switch` | `tab.new` / `tab.close` / `tab.select` | pełny |
| `set_view` | `view.setMode` | pełny |
| `select` | `selection.byMask` | pełny |
| `quick_filter` | `panel.quickFilter` | pełny |
| `open_preview` | `view.previewPanel` | odczyt |
| `copy_paths_to_clipboard` | `clipboard.copyPaths` | pełny |
| `color_rules_get` / `color_rules_set` | `colors.get` / `colors.set` | pełny |
| `copy` / `move` / `trash` | `file.copy` / `file.move` / `file.trash` | za zgodą |
| `mkdir` / `new_file` | `file.mkdir` / `file.newFile` | za zgodą |
| `rename` | `file.rename` | za zgodą |
| `set_attributes` / `set_tags` | `file.setAttributes` / `file.setTags` | za zgodą |
| `undo` | `edit.undo` | za zgodą |
| `run_command` | dowolna komenda z rejestru | za zgodą, ale nie wyżej niż poziom komendy |
| `search`, `spotlight_search`, `saved_search_run/list` | `search.*` | pełny |
| `find_duplicates` | `search.duplicates` | odczyt |
| `multi_rename`, `split_file`, `join_files` | `file.multiRename`, `file.split`, `file.join` | za zgodą |
| `checksum`, `checksum_verify` | `file.checksumCreate`, `file.checksumVerify` | pełny |
| `archive_create`, `archive_extract` / `archive_list`, `archive_test` | `archive.*` | za zgodą / odczyt |
| `remote_connections`, `remote_open`, `remote_list`, `remote_read`, `remote_search` | `remote.*` | odczyt (tylko aliasy) |
| `compare_files`, `compare_dirs`, `sync_preview` | `file.compare`, `dirs.compare`, `sync.preview` | odczyt |
| `sync_run`, `sync_job_save`, `sync_job_run` / `sync_job_list` | `sync.*` | za zgodą / odczyt |
| `device_list`, `device_open` | `device.*` | odczyt |

Poziom wywołania = min(poziom komendy, nadpisania, poziomy wszystkich zasobów: SFTP/WebDAV/SMB/chmury
i woluminy sieciowe — odczyt, FTP — za zgodą, archiwa/urządzenia — odczyt, zablokowane — brak).

## 9. Interfejs (cel Bifold.app)

- `MainWindowController` → zagnieżdżone `NSSplitView`: [panel lewy | panel prawy], pod spodem
  linia poleceń i (rozwijany) terminal SwiftTerm, na dole pasek kolejki operacji.
- `PanelViewController`: pasek kart (`TabBarView`), pasek ścieżki, opcjonalne drzewo
  (`DirectoryTreeView`, `NSOutlineView`), widok plików wymienny (protokół `FileListView`):
  `DetailsListView` (`NSTableView`), `GridListView` w stylu `.brief` (lista skrócona) albo
  `.thumbnails` (miniatury, `NSCollectionView` + `QLThumbnailGenerator`), `ColumnListView`
  (`NSBrowser`), panel szybkiego podglądu (`QuickViewPane`, `QLPreviewView`), pasek stanu.
- Klawisze: skróty z `Keymap` są odpowiednikami klawiszowymi pozycji menu (menu z rejestru).
  Widoki plików przekazują `keyDown` do `PanelViewController.handleKey`, który obsługuje szybkie
  wyszukiwanie po literach, Escape i pozostałe skróty z `Keymap` (`workspace.perform`), a strzałki
  itp. oddaje widokowi. Tylko `ColumnListView` używa lokalnego monitora `NSEvent` (`NSBrowser`
  sam przechwytuje klawisze).
- `ViewerWindowController` (F3): tekst (`NSTextView`, wybór kodowania), hex (HexFiend `HFTextView`),
  obrazy (`NSImageView`). Quick Look: `QLPreviewPanel` (`QuickLookController`).
- Ustawienia i okna dialogowe: SwiftUI w oknach AppKit (`NSHostingController`).
