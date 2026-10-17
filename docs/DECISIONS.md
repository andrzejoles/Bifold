# Decyzje projektowe

Format: data — decyzja — powód. Najnowsze na dole.

### D1 · 2026-10-17 — Praca autonomiczna zamiast czekania na akceptację
Użytkownik polecił wykonać `PROMPT.md` „w pełni autonomicznie”. Punkty „pokaż i poczekaj na
akceptację” oraz „zapytaj” zastępuję wpisami w tym pliku: każda decyzja, o którą miałem pytać,
jest tu opisana z uzasadnieniem, żeby dało się ją łatwo zmienić.

### D2 · 2026-10-17 — XcodeGen (`project.yml`) jako źródło projektu Xcode
Ręczna edycja `project.pbxproj` jest podatna na konflikty i błędy. `project.yml` jest czytelny,
a wygenerowany `Bifold.xcodeproj` jest commitowany, więc do zwykłego budowania w Xcode XcodeGen
nie jest potrzebny (tylko przy zmianie struktury celów).

### D3 · 2026-10-17 — Nazwa i bundle id w `Config/Brand.xcconfig`
`PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER` i nazwa katalogu w Application Support pochodzą z
jednego pliku; kod czyta je z `Info.plist` (`Brand.swift`).

### D4 · 2026-10-17 — Kosz przez `FileManager.trashItem(at:resultingItemURL:)`
PROMPT wskazuje `NSWorkspace.recycle`. `FileManager.trashItem` robi to samo (ten sam mechanizm
Findera, zwraca nową ścieżkę w Koszu), ale działa synchronicznie i bez AppKit, więc może żyć w
`BifoldCore` i być testowane bez interfejsu. Nowa ścieżka w Koszu trafia do dziennika.

### D5 · 2026-10-17 — Kopiowanie przez `copyfile(3)` z callbackiem postępu
`COPYFILE_ALL` zachowuje dane, xattr, ACL i daty; `COPYFILE_CLONE` daje natychmiastowe klony na
APFS. Callback `COPYFILE_STATE_STATUS_CB` służy do postępu, pauzy (blokada w callbacku), limitu
prędkości (uśpienie w callbacku) i anulowania (`COPYFILE_QUIT`). Kopiowanie do pliku tymczasowego
`.bifold-partial` i atomowe `rename` na końcu — po anulowaniu nie zostaje częściowy plik.

### D6 · 2026-10-17 — Obserwacja modelu w AppKit przez `withObservationTracking`
Model to `@Observable` (framework Observation). Widoki AppKit rejestrują się helperem
`observe { … }`, który ponawia śledzenie po każdej zmianie (na głównym aktorze). Bez Combine.

### D7 · 2026-10-17 — Teksty interfejsu: klucze = polskie zdania, katalog w aplikacji
Polski jest językiem źródłowym, więc klucze `String(localized:)` są polskimi tekstami. Moduły SPM
używają `L10n.tr("…")`, który szuka tłumaczenia w `Bundle.main` (katalog `Localizable.xcstrings`
celu aplikacji). Skrypt `scripts/gen-strings.py` zbiera klucze z całego kodu i dopisuje brakujące
do katalogu, żeby dodanie nowego języka było kompletne.

### D8 · 2026-10-17 — HexFiend jako submoduł budowany skryptem
HexFiend nie ma pakietu SPM. Submoduł `ThirdParty/HexFiend` (tag v2.18.1) budowany jest przez
`scripts/build-hexfiend.sh` (cel `HexFiend_Framework`, arm64, Release) do `ThirdParty/build/`,
skąd aplikacja go linkuje i osadza. Sprawdzone: buduje się na Xcode 27 bez błędów.

### D9 · 2026-10-17 — Wykrywanie Full Disk Access
Brak oficjalnego API. Próba otwarcia do odczytu `~/Library/Application Support/com.apple.TCC/TCC.db`
(chroniony przez TCC); `EPERM` → brak FDA. Okno z instrukcją i przyciskiem otwierającym
`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

### D10 · 2026-10-17 — Klawiatura: własny `KeyRouter` zamiast tylko `keyEquivalent` menu
Skróty TC (F-klawisze, Tab, Spacja, litery w szybkim wyszukiwaniu) nie mieszczą się w modelu
`keyEquivalent`. `KeyRouter` dopasowuje `NSEvent` do `KeyChord` z aktywnego `Keymap` i wywołuje
komendę z rejestru; menu pokazuje te same skróty (jeśli da się je wyrazić jako `keyEquivalent`).

### D11 · 2026-10-17 — Poziom „Odczyt” pozwala zmieniać stan interfejsu
Macierz daje poziom „Odczyt” m.in. dla drzewa katalogów, podglądu, Quick Look i przełączania
paneli. Polityka agenta (Etap 2) dopuszcza przy poziomie „Odczyt” komendy o skutkach `none`
i `uiState` (nie zmieniają plików ani ustawień), a odrzuca `modifiesFiles`, `external`, `settings`.

### D12 · 2026-10-17 — Bez skrótów Option+litera
Na polskim układzie klawiatury Option+litera wpisuje ą, ę, ł… Skróty TC z Alt+literą (atrybuty)
mają zamienniki Ctrl+Alt+litera, a szybkie wyszukiwanie w panelu przyjmuje polskie litery.

### D13 · 2026-10-17 — Klucz sortowania nazw zamiast `localizedStandardCompare`
Sortowanie 100 000 nazw przez `localizedStandardCompare` trwało ~0,6 s nawet w Release.
`NameCollation` liczy klucz raz na nazwę (kolejność naturalna liczb, polskie litery po literach
bazowych, bez rozróżniania wielkości liter); remisy rozstrzyga `localizedStandardCompare`.
Test zgodności z kolejnością Findera dla typowych nazw: `NameCollationTests`. Wynik: 100 000
plików — listowanie + sortowanie ≈ 0,3 s (Debug).

### D14 · 2026-10-17 — Nadpisywane pliki trafiają do Kosza
Przy konflikcie „Nadpisz” stary plik jest przenoszony do Kosza (i zapisywany w dzienniku),
a nie usuwany. Dzięki temu kopiowanie/przenoszenie z nadpisaniem da się w pełni cofnąć.

### D15 · 2026-10-17 — Linia poleceń przez interaktywną powłokę w terminalu
PROMPT mówi o `$SHELL -lc`. Polecenie trafia do wbudowanego terminalu (SwiftTerm), w którym
działa powłoka logowania (`$SHELL -l`) — wynik zostaje w historii terminalu, a `cd` w linii
poleceń zmienia katalog panelu (jak w TC). Zmienna `BIFOLD_AGENT_TOKEN` jest usuwana ze
środowiska terminalu.

### D16 · 2026-10-17 — Repozytorium prywatne
Repozytorium GitHub `andrzejoles/Bifold` jest prywatne (narzędzie do użytku własnego).

### D17 · 2026-10-17 — Most bez SDK MCP, serwer MCP w aplikacji
`bifold-mcp` (BifoldBridgeKit, sama Foundation) tylko przekazuje linie JSON-RPC ze stdio do ramek
gniazda i z powrotem. Serwer MCP (swift-sdk 0.12.1) działa w aplikacji z własnym transportem
`SocketTransport`. Most nie ma żadnej logiki uprawnień, więc jego podmiana niczego nie daje.

### D18 · 2026-10-17 — Token: środowisko procesu, zapasowo środowisko przodka
Token jest tylko w środowisku procesu CLI. Część CLI nie przekazuje zmiennych środowiskowych
serwerom MCP (Codex domyślnie filtruje środowisko). Most szuka wtedy `BIFOLD_AGENT_TOKEN`
w środowisku swoich przodków (`sysctl KERN_PROCARGS2`, ten sam UID). Nie osłabia to modelu
zagrożeń: proces tego samego użytkownika i tak mógłby odczytać środowisko (SECURITY.md §3), a
serwer dodatkowo wymaga, żeby most był potomkiem procesu CLI sesji.

### D19 · 2026-10-17 — Normalizacja `initialize`
Codex, Claude Code i Antigravity deklarują `capabilities.elicitation: {form, url}` z nowszej
specyfikacji MCP, czego swift-sdk 0.12.1 nie dekoduje (błąd -32603). Serwer Bifolda nie korzysta
z możliwości klienta, więc transport zastępuje je pustym obiektem w żądaniu `initialize`.

### D20 · 2026-10-17 — `run_command` najwyżej „Za zgodą”
`run_command` daje dostęp do całego rejestru, więc poziom wywołania przez to narzędzie to
min(poziom komendy, „Za zgodą”). Komendy „Pełny” wywołane przez `run_command` wymagają zgody,
komendy „Brak” są niedostępne.

### D21 · 2026-10-17 — Konfiguracja MCP na sesję — zweryfikowana testem E2E
| Agent | Sposób | Wynik testu `AgentE2ETests` |
|---|---|---|
| Claude Code 2.1.302 | `--mcp-config <json> --strict-mcp-config`, tryb ścisły `--tools "" --allowedTools mcp__bifold__*` | ✔ |
| Codex 0.162.1 | `-c mcp_servers.bifold.*`, `env_vars`, tryb ścisły `--sandbox read-only` | ✔ |
| Grok | `GROK_CONFIG=<plik sesji>` (nakładka), `--sandbox read-only` | ✔ (start ~4 min) |
| Antigravity | trwałe `agy mcp add bifold …` za zgodą, `--sandbox` | ✔ |

### D22 · 2026-10-17 — Znaczniki sesji CLI usuwane ze środowiska agenta
Jeśli Bifold uruchomiono z terminala, w którym działało CLI agenta, zmienne `CLAUDECODE`,
`CLAUDE_CODE_*`, `CODEX_*` nie przechodzą do CLI uruchamianego w panelu agenta.

### D23 · 2026-10-17 — Okno zatwierdzania bez przycisku domyślnego
Test w aplikacji pokazał, że Enter wciśnięty w terminalu agenta tuż przed pojawieniem się arkusza
mógł zatwierdzić operację. Teraz „Zatwierdź” nie ma skrótu klawiszowego i włącza się po 0,8 s,
Esc odrzuca. Zgoda wymaga kliknięcia.

### D24 · 2026-10-17 — Teksty do procesów nie przez argumenty (`Process` → NFD)
`Process` przekazuje argumenty w postaci `fileSystemRepresentation`, czyli NFD. Wzorzec
„gęślą” w NFD nie pasuje do tekstu w NFC, więc ripgrep dostaje wzorzec z pliku (`--file`,
plik tymczasowy 0600). Ścieżki mogą iść argumentami (system plików i tak normalizuje).

### D25 · 2026-10-17 — Żadnych odczytów atrybutów rozszerzonych na głównym wątku
Zawieszony start aplikacji: kolumna „Tagi” czytała tagi Findera (`getxattr`) na głównym wątku,
a dla folderu File Provider (OneDrive) wywołanie blokowało się. Tagi wczytuje teraz jedna kolejka
w tle, a wiersz odświeża się po odczycie.

### D26 · 2026-10-17 — `DirectoryWatcher.stop()` asynchronicznie
`queue.sync` przy anulowaniu strumienia zakleszczał się z callbackiem FSEvents czekającym na
blokadę `AsyncStream` (wykryte w pełnym przebiegu testów). Zatrzymanie idzie przez `queue.async`.

### D27 · 2026-10-17 — Wyniki wyszukiwania jako dostawca `search:<id>`
Wyniki (Alt+F7, Spotlight, duplikaty) trafiają do nowej karty z dostawcą `SearchResultsFS`;
elementy mają prawdziwe ścieżki lokalne, więc działają na nich wszystkie komendy. Operacje
tworzące pliki w takiej karcie są zablokowane. Karty wyników nie są przywracane po restarcie.

### D28 · 2026-10-17 — Zmiana nazw wielu plików: maski TC + rozszerzenia
Składnia jak w TC (`[N]`, `[E]`, `[N2-5]`, `[C]`, `[P]`, `[Y][M][D]`…) plus `[Exif:Pole]`,
`[Exif:DateTimeOriginal:format]` (ImageIO) i `[Media:artist|title|album|year]` (AVFoundation).
Zamiany nazw w obrębie zbioru (a↔b) idą przez nazwy tymczasowe i każdy krok trafia do dziennika,
więc cofanie jest dokładne.

### D29 · 2026-10-17 — Archiwa: jeden backend 7zz, hasło przez stdin
Listowanie `7zz l -slt`, odczyt `e -so`, rozpakowanie `x` z plikiem listy (`@lista`, UTF-8 —
omija zamianę argumentów na NFD), hasło przez standardowe wejście (nie w argumentach widocznych
w `ps`), nigdy zapisywane. Klucze ścieżek w `ArchiveFS` normalizowane do NFC. tar.gz/bz2/xz:
najpierw tar, potem kompresja (7zz nie robi tego jednym poleceniem). Kopiowanie z archiwum:
rozpakowanie do katalogu tymczasowego na woluminie docelowym i przeniesienie silnikiem kopiowania
(konflikty, dziennik jako kopie — cofnięcie = Kosz). Archiwa są tylko do odczytu; `LocalFS`
odrzuca każdą ścieżkę innego dostawcy, a komendy zmieniające pliki odrzucają elementy archiwum.
Wyszukiwanie w archiwach dotyczy nazw (bez treści).

### D30 · 2026-10-17 — rclone: gniazdo Unix, konfiguracja w pamięci, hasła w Keychain
`rclone rcd --rc-addr unix://…/run/rclone.sock --rc-no-auth --config ""` — bez portów TCP,
bez pliku konfiguracji (sprawdzone testem: `config/paths` nie wskazuje istniejącego pliku, a
`config/dump` nie zawiera jawnego hasła). Zasoby tworzy `config/create` z `obscure`, hasła
i tokeny są w Keychain (usługa `<bundle id>.remote`), definicje połączeń bez sekretów
w `connections.json`. Klient HTTP/1.1 po gnieździe Unix napisany ręcznie (URLSession nie
obsługuje gniazd Unix). Przy zbyt długiej ścieżce gniazda — prywatny katalog 0700 w /tmp.

### D31 · 2026-10-17 — Poziomy zasobów dla agenta (PROMPT.md 5.5)
`Workspace.resourceAccess`: SFTP/WebDAV/SMB/chmury — odczyt, FTP/FTPS — za zgodą, woluminy
sieciowe (statfs bez MNT_LOCAL) — odczyt, archiwa i wyniki — odczyt, lokalne — pełny. Bramka
agenta bierze minimum ze wszystkich zasobów wywołania (także celu i źródeł w `alias:/ścieżka`).
Testem potwierdzone: zapis na SFTP zabroniony mimo zgody, FTP za zgodą, FTP→SFTP zabronione.

### D32 · 2026-10-17 — Operacje na serwerach nie są cofalne (poza pobraniem)
Pobranie na dysk lokalny trafia do dziennika (cofnięcie = Kosz). Wysyłanie, zmiana nazwy
i usuwanie na serwerze nie mają operacji odwrotnej (serwery nie mają Kosza) — dlatego usuwanie
z serwera jest zawsze potwierdzane przez użytkownika, a dla agenta możliwe tylko na FTP po zgodzie.
Pauza zadania rclone = globalny limit 1 B/s (rc nie ma pauzy zadań).

### D33 · 2026-10-17 — Plan synchronizacji z listingów, sumy na żądanie
Domyślnie plan powstaje z rekurencyjnych listingów obu stron (rozmiar + data, tolerancja 2 s —
jak w TC), bo `operations/check` liczy sumy kontrolne wszystkich plików i na dużym drzewie trwa
bardzo długo. Tryb „sumy kontrolne” używa `operations/check`. Tryby: lustro (z usuwaniem),
aktualizacja, dwukierunkowa (nowszy wygrywa, bez usuwania — przewidywalna, z pełnym podglądem;
świadomie bez `rclone bisync`, który wymaga stanu z poprzednich przebiegów). Wykonanie idzie
pozycja po pozycji, więc odznaczone w podglądzie pozycje są pomijane; lokalne pliki nadpisywane
i usuwane trafiają najpierw do Kosza (cofalne).

### D34 · 2026-10-17 — Odświeżenie w tle nie nadpisuje nowszego kursora
Wykryte w teście: odświeżenie po zdarzeniu FSEvents przywracało stary kursor po równoległej
nawigacji z fokusem. Karta liczy nawigacje; odświeżenie przywraca kursor tylko, jeśli w międzyczasie
nie było innej nawigacji.
