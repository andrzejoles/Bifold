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
(Obecnie bez osobnej klasy `KeyRouter`: dopasowanie robi `PanelViewController.handleKey`, do którego
widoki plików przekazują `keyDown`; skróty wyrażalne w menu działają jako `keyEquivalent`.)

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
**Uzupełnione 2026-10-28:** pierwsze słowo będące plikiem wykonywalnym w bieżącym (lokalnym) katalogu
dostaje `./` (`run.sh` → `./run.sh`), jak w TC — ale tylko gdy nie ma takiego polecenia w `PATH`, żeby
plik podrzucony do katalogu (np. `ls`) nie przesłaniał polecenia systemowego.

### D16 · 2026-10-17 — Repozytorium prywatne
Repozytorium GitHub `andrzejoles/Bifold` jest prywatne (narzędzie do użytku własnego).
**Zmienione 2026-10-17 (decyzja właściciela):** repozytorium publiczne, licencja MIT — kod i aplikację można udostępniać; wymagają tego też automatyczne aktualizacje (D40).

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

### D35 · 2026-10-17 — Urządzenia przez narzędzia CLI libmtp i libimobiledevice
Android: `mtp-folders` / `mtp-files` (drzewo z identyfikatorów, jedna sesja MTP naraz),
`mtp-getfile` do kopiowania. iPhone: `afcclient` (`ls -l`, `get -rf`, `--documents <bundle id>`
dla aplikacji z udostępnianiem plików), uruchamiany z `LC_ALL=C` (stały format dat).
Narzędzia zamiast linkowania dylibów z /opt/homebrew — prostsze, bez kruchego mapowania struktur C.
Urządzenia są tylko do odczytu (macierz: agent — odczyt); kopiowanie z telefonu idzie tym samym
torem co kopiowanie z archiwum. Parsery przetestowane na przykładowych wyjściach — bez fizycznego
telefonu nie było testu na żywo.

### D36 · 2026-10-17 — Pomocnik administratora: SMAppService + XPC + Authorization Services
`bifold-helper` (LaunchDaemon w `Contents/Library/LaunchDaemons`) przyjmuje połączenia XPC tylko od
klienta spełniającego wymaganie podpisu (`BIFOLD_CLIENT_REQUIREMENT`) i wykonuje wyłącznie
operacje `HelperOperation` (właściciel, prawa, nowy katalog, przeniesienie, kopia, usunięcie) na
zweryfikowanych ścieżkach (realpath rodzica, katalogi systemowe zabronione). Każda operacja ma własne
prawo w bazie autoryzacji z regułą „hasło administratora, bez pamiętania” i jest sprawdzana przez
demona. **Ograniczenie:** demony SMAppService wymagają podpisu z zespołem — przy „Sign to Run Locally”
rejestracja się nie powiedzie; ustaw `DEVELOPMENT_TEAM` i wymaganie z certyfikatem w
`Config/Brand.xcconfig`. Instalacja i działanie demona nie były testowane end-to-end (wymaga
zatwierdzenia przez użytkownika); logika operacji i walidacji ma testy jednostkowe.

### D37 · 2026-10-17 — SCP przez systemowe `ssh`/`scp -O`, nie przez rclone
rclone nie ma klasycznego SCP, a serwery bez SFTP (np. AIX 6.1, na którym właściciel go potrzebuje)
obsługują tylko SCP. `ScpFS`: listing z `ls -la` (lokalizacja C), operacje przez SSH, kopiowanie plik
po pliku z jawną nazwą docelową (działa też dla nazw w ISO-8859-2). Jedno połączenie główne
(ControlMaster, ControlPersist 15 min) na serwer — kolejne polecenia nie logują się ponownie.
Procesy przez `posix_spawn` z dokładnymi bajtami argumentów (`Process` zamienia je na NFD, co psuje
polskie nazwy na serwerach porównujących bajty). Ścieżki dla `scp -O` z odwrotnym ukośnikiem przed
znakami specjalnymi — apostrofy nie przechodzą kontroli nazw nowego klienta. Przenoszenie (F6) z/na SCP
celowo nieobsługiwane (komunikat: skopiuj, potem usuń). Synchronizacja i wyszukiwanie na serwerze SCP —
nieobsługiwane (wymagają rclone).

### D38 · 2026-10-17 — Hasło dla `ssh` przez jednorazową kolejkę FIFO
`SSH_ASKPASS` wskazuje skrypt `cat "$BIFOLD_ASKPASS_FIFO"` (bez sekretu). Aplikacja zapisuje hasło do
kolejki FIFO (0600, katalog 0700) raz, gdy `ssh` ją otworzy, potem kolejka znika. Hasło nie trafia do
argumentów, zmiennych środowiskowych (te są czytelne dla innych procesów użytkownika przez
`KERN_PROCARGS2`) ani plików. Bez hasła: `BatchMode=yes` (klucz lub agent SSH).

### D39 · 2026-10-17 — Weryfikacja klucza serwera dla SFTP
Do tej pory rclone łączył się z SFTP bez `known_hosts_file`, czyli przyjmował każdy klucz serwera
(podstawiony serwer mógł przechwycić hasło). Teraz przed połączeniem `ssh` z `accept-new` zapisuje
klucz nowego serwera w `~/.ssh/known_hosts` (zaufanie przy pierwszym połączeniu, jak w `ssh`), a rclone
dostaje ten plik i algorytmy klucza zgodne z zapisanym typem. Zmieniony klucz blokuje połączenie (test).

### D40 · 2026-10-17 — Wersjonowanie, autor, aktualizacje jak w CantatePresenter (decyzja właściciela)
Wersja z historii gita (`scripts/version.sh`, ta sama reguła co w CantatePresenter), numer kompilacji =
liczba commitów; zmiany na `main` przez PR scalane zwykłym „Merge pull request”. Wersja trafia do
budowania przez `build/Version.xcconfig` (akcja wstępna schematu) — modyfikacja Info.plist po
przetworzeniu ścigała się z Xcode. Autor: „Andrzej Oleś w kooperacji z Claude AI” (Info.plist, okno
„O programie”, LICENSE, README). Aktualizacje: Sparkle 2.9.6 (obecnie 2.10.1), kanał `releases/latest/download/appcast.xml`,
klucz EdDSA w Pęku kluczy (konto `bifold`), automatyczne pobieranie i instalacja przy zamknięciu.
Licencja MIT (wybór domyślny przy udostępnianiu; zmiana = podmiana pliku LICENSE).

### D41 · 2026-10-17 — Stały podpis certyfikatem z własnym podpisem
Podpis ad-hoc zmienia się przy każdej kompilacji, a macOS wiąże z nim Pełny dostęp do dysku i dostęp
do haseł w Pęku kluczy (CantatePresenter opisuje ponowne pytania po aktualizacji). `scripts/signing.sh`
tworzy certyfikat „Bifold Self-Signed” w osobnym pęku kluczy (hasło losowe w pęku logowania), a
wymaganie podpisu to „identyfikator + certyfikat” — stałe między wersjami (sprawdzone na aktualizacji
1.0.14 → 1.0.15). Nie zastępuje Developer ID: Gatekeeper ostrzega przy pierwszym uruchomieniu, a
pomocnik administratora nadal wymaga zespołu (D36).

### D42 · 2026-10-17 — Tłumaczenia interfejsu jak w CantatePresenter (decyzja właściciela)
Języki wbudowane: pl (źródłowy), en, de, es, uk — ten sam zestaw co w CantatePresenter; tłumaczenia
przygotowane przez Claude, do przejrzenia przez osoby znające języki. Wybór w Ustawieniach (domyślnie
jak w systemie), zapis w UserDefaults (`BifoldLanguage`, potrzebny przed zbudowaniem komend), zmiana po
ponownym uruchomieniu — tytuły komend i menu powstają przy starcie. Eksport/import w formacie JSON
podobnym do CantatePresenter (`bifold-i18n-v1`: klucz = polski tekst, kontekst = angielski, instrukcja
dla AI). Zaimportowany język zapisywany jako `<dane>/languages/<kod>.lproj/Localizable.strings`, więc
`String(localized:)` korzysta z niego bez przebudowy (sprawdzone, także z `%1$@`). Tłumaczenia z
niezgodnymi znacznikami odrzucane (inaczej `String(format:)` może zatrzymać aplikację).
`scripts/gen-strings.py` bierze klucze z plików `.stringsdata` kompilatora: wcześniejsze zgadywanie
typów (`%@`/`%lld`) dało 18 błędnych kluczy, których nie dało się przetłumaczyć.

### D43 · 2026-10-17 — Jedna kopia aplikacji w systemie
Xcode rejestruje każdą zbudowaną aplikację w LaunchServices, a Spotlight znajduje kopie w `build/` i
`dist/` — w Launchpadzie było pięć „Bifoldów”. Katalog budowania to `build/DerivedData.noindex`, kopie
robocze instalatora w `dist/staging.noindex`, a `make build`, instalator i `make unregister`
wyrejestrowują wszystko poza `/Applications`.

### D44 · 2026-10-19 — Terminal SSH jako karta panelu (decyzja właściciela)
„Jak uruchamiasz z Menedżera połączeń połączenie ssh, to w drugim panelu zamiast listy plików otwiera się
terminal”. Karta panelu może mieć `terminal` (`TerminalSpec`): panel pokazuje wtedy SwiftTerm z `ssh -t`
przez połączenie główne (ControlPath) — hasło podało już połączenie główne z Pęku kluczy, w argumentach
nie ma sekretów. Katalog startowy z panelu przez `cd … && exec $SHELL -l`, tylko dla powłok znających `-l`
(ksh88 z AIX nie zna — wtedy zwykłe logowanie w katalogu domowym). Klawisze bez Cmd przejmuje widok
terminala przed menu (F5 ma trafić do `mc` na serwerze, nie do kopiowania plików). Agent nie otwiera
terminala ani nie widzi jego treści (`remote.terminal` — poziom „Brak”; `remote.open` od agenta pomija
terminal). Karty-terminale nie wracają po ponownym uruchomieniu. Próby na żywo bez dotykania danych:
`BIFOLD_DATA_DIR`, `BIFOLD_SSH_CONFIG`, `BIFOLD_SSH_KNOWN_HOSTS`.

### D45 · 2026-10-19 — Android przez własnego pomocnika na libmtp (zmiana D35)
Narzędzia CLI libmtp nie czytają pojedynczego folderu: `mtp-files`/`mtp-folders` wyliczają cały telefon,
co na prawdziwym Samsungu trwało ponad 2 minuty bez wyniku (panel pusty). `Tools/bifold-mtp/bifold-mtp.c`
(budowany przez `scripts/build-mtp-helper.sh`, linkowany dynamicznie z libmtp z Homebrew — biblioteka nie
trafia do aplikacji) otwiera urządzenie bez pamięci podręcznej (`LIBMTP_Open_Raw_Device_Uncached`) i
odpowiada na `storages`/`list`/`get` w jednej sesji. Samsung nie pokazuje nośników, dopóki na telefonie
nie wybrano „Zezwól” — wtedy komunikat i ponowna próba bez zamykania sesji. Testy na fałszywym pomocniku
(skrypt z tym samym protokołem).

### D46 · 2026-10-26 — Nazwy z urządzeń są niezaufane; jedna linia nazwy w wierszu
Telefon (albo udające go urządzenie USB) podaje dowolne nazwy. `MTPDeviceFS` pomija nazwy, których nie można
użyć jako składnika ścieżki (`validateFileName` + znaki sterujące), bo trafiają do ścieżek lokalnych przy
kopiowaniu i do wierszowego protokołu `bifold-mtp` (znak nowej linii dodałby polecenie `get` z dowolną
ścieżką docelową); pomocnik dodatkowo odrzuca ścieżki ze znakami sterującymi. Narzędzia urządzeń idą
przez `Spawn` z limitem czasu.
Długie nazwy w listach: jedna linia z wielokropkiem w środku i pełną nazwą w podpowiedzi (jak Finder i TC),
a nie wiersze o zmiennej wysokości — przy 100 000 elementów wysokość każdego wiersza wymagałaby mierzenia
tekstu przy każdym przeładowaniu, a stała wysokość jest potrzebna do przewijania i nawigacji klawiaturą.

### D47 · 2026-10-26 — Wygrywa ostatnia nawigacja; odświeżenie jej nie unieważnia (rozszerza D34)
Wykryte w przeglądzie: wynik wolnego wczytania katalogu (serwer, odświeżenie po FSEvents przy obciążeniu)
nadpisywał kartę, nawet jeśli w międzyczasie przeszło się gdzie indziej. Teraz wynik wczytania obowiązuje
tylko, gdy od jego początku nie było nowszej nawigacji. Odświeżenie nie podbija numeru nawigacji (nie może
unieważnić jawnej nawigacji, np. wejścia do archiwum) i jego wynik obowiązuje tylko w tym samym katalogu.
Testy `NavigationRaceTests` (dostawca z wolnym katalogiem) sprawdzają oba kierunki wyścigu.
Uzupełnienie (przegląd, część 3): odświeżenie jest pomijane także wtedy, gdy w jego trakcie jakakolwiek
jawna nawigacja zastosowała wynik (inaczej przywracało kursor sprzed F7/„Nowy plik” w tym samym katalogu).

### D48 · 2026-10-26 — Bramka agenta zamraża wywołanie
Przegląd wykazał rozbieżności między bramką a komendą (inna baza ścieżek względnych, cele domyślne
czytane na żywo, prefiks `alias:`), które pozwalały agentowi czytać zablokowane pliki, oraz okno między
zgodą a wykonaniem. Zamiast kazać każdej komendzie deklarować zasoby, bramka (`ArgumentFreezer`) rozwija
argumenty do ścieżek absolutnych tą samą funkcją co komenda i `Workspace.invoke` wykonuje komendę z tymi
argumentami; gdy celu nie da się zapisać ścieżką — porównanie stanu paneli po zgodzie. Wywołania jednej
sesji przechodzą przez bramkę po kolei. Operacje rekurencyjne na przodku zablokowanej ścieżki są
odrzucane (prościej i pewniej niż wycinanie poddrzew). Dziennik nie zawiera treści plików.

### D49 · 2026-10-26 — Tożsamość elementu zamiast tekstu ścieżki; Kosz i cofanie
Silnik kopiowania rozpoznaje „ten sam element” po (dev, ino), a „cel wewnątrz źródła” po i-węzłach w górę
ścieżki rzeczywistej (APFS bez rozróżniania wielkości liter, dowiązania, firmlinki). Trwałe usunięcie
zamiast Kosza tylko dla jawnego „wolumin bez Kosza” (doprecyzowanie D14). Partia dziennika trwającego
zadania nie jest cofalna; częściowe cofnięcie oznacza pojedyncze wpisy; dziennik ma stały uchwyt
`O_APPEND` i jest przycinany przy starcie. „Rozpakuj archiwa” do istniejącego katalogu idzie przez
katalog tymczasowy i TransferEngine (Kosz, dziennik); archiwa powstają pod nazwą tymczasową.

### D50 · 2026-10-26 — Serwery: SCP jak kopiowanie lokalne, jedna sesja SSH na serwer
Wysyłanie katalogu na istniejący katalog scala (bez `rm`), konflikty plików przez delegata lub politykę,
pominięte w raporcie; pobieranie odtwarza dowiązania (rekurencja tylko w prawdziwe katalogi), kolizje
wielkości liter dostają „nazwa (2)”. Nazwy z listingu UTF-8 bez normalizacji (NFC tylko dla nowych nazw
i Latin-2). Jedna `SSHSession` na alias, blokada startu połączenia głównego na ControlPath, ponawianie
tylko poleceń idempotentnych. SFTP/FTP/WebDAV: rename/nowy plik/katalog odmawiają, gdy cel istnieje.
Limit prędkości rclone wspólny dla procesu: minimum z niewstrzymanych zadań, 1 B/s gdy wstrzymane wszystkie.

### D51 · 2026-10-26 — Identyfikatory pomocnika z Brand.xcconfig; telefony po USB
Plik demona generowany przy budowaniu z `BIFOLD_BUNDLE_ID`, nazwa usługi Mach z Info.plist (albo bundle
id + `.helper`) — zmienia uwagę w D36. Android identyfikowany po vid:pid (+bus:dev), żeby ponowne
otwarcie po odłączeniu jednego z dwóch telefonów nie trafiło w drugi (rozszerza D45); iPhone po pełnym UDID.

### D52 · 2026-10-26 — Karta zachowuje maszynę także przy zamianie paneli
⌃U zamienia całe karty (z historią i tytułem), nie tylko katalogi (rozszerza D44/D47). Tytuł karty wynika
z dostawcy ścieżki. Domyślny cel kopiowania i rozpakowania to tylko lokalny katalog drugiego panelu.
Dostawcy archiwów i wyników są wyrejestrowywani, gdy nie używa ich żadna karta ani wpis historii.

### D53 · 2026-10-26 — Klawisze w polach tekstowych, oknach pomocniczych i terminalach
Komendy panelu działają z menu tylko, gdy kluczowe jest okno główne (lub Quick Look); w polu tekstowym
skróty edycji (⌘Z/⇧⌘Z/⌘X/⌘C/⌘V/⌘A, w innych oknach ⌘W/⌘F) należą do AppKitu. Dolny terminal przejmuje
klawisze bez Cmd jak karta-terminal (D44), oprócz skrótu terminala. W karcie-terminalu Ctrl+Tab przełącza
panel (Tab musi trafiać do serwera), ⌘W zamyka kartę, gdy profil nie ma „Zamknij kartę” z Cmd. Widok
kolumn tylko dla dysku lokalnego, poziomy wczytywane w tle. Skróty przechwytywane przez macOS: Spotlight
⌃⌥F, duplikaty ⌃⌥D, sortowanie w profilu TC także ⌃⌘1–5; kolejność skrótów komendy jest stała.

### D54 · 2026-10-26 — Przegląd przez subagentów
Trzecia runda przeglądu: sześciu recenzentów (Core, serwery/urządzenia/pomocnik, Workspace, agent, UI,
stos/build) tylko do odczytu, potem sześciu wykonawców w osobnych worktree z rozłącznymi plikami;
każde ustalenie weryfikowane testem przed poprawką. Dokumentację uzupełnia koordynator po scaleniu.

### D55 · 2026-10-27 — Przegląd, część 4: cofanie, dziennik, nawigacja (decyzja właściciela)
Krok cofania, którego elementu już nie ma (`.missing`, np. opróżniony Kosz), liczy się jak wykonany —
inaczej partia blokowała Cmd+Z na zawsze. Kopia katalogu zapisuje liczbę elementów poddrzewa (bez
`.DS_Store`); inna liczba przy cofaniu to konflikt „zmieniony”. Dziennik przycinany przy starcie do 1000
partii / 100 000 wpisów / 32 MB (najnowsza partia zostaje zawsze). Jawna nawigacja liczy się jako
zastosowana zaraz po ustawieniu kursora (uzupełnia D47). Tytuł karty tylko z dostawcy (`setPath`); ręcznie
zostają „⌨” i telefon. Martwe wpisy historii są usuwane przy Wstecz/Dalej. ⌃U przenosi też karty-terminale
(agent nie). Okno synchronizacji wykonuje sprawdzony plan bezpośrednio przez kolejkę (wyjątek od zasady
„czynność = komenda”, bo `sync.run` liczy plan od nowa). Widok kolumn trzyma tylko poziomy bieżącej
ścieżki i widocznych kolumn, a dopóki w tle wczytuje się nowa lista — pokazuje dotychczasową.

### D56 · 2026-10-27 — SCP: nadpisywanie przez plik tymczasowy, sesje po gnieździe, MTP po USB (decyzja właściciela)
Nadpisywanie na SCP idzie przez plik tymczasowy w katalogu docelowym i `mv -f` (przerwanie nie psuje
pliku); plik dostaje właściciela wysyłającego i prawa z kopii lokalnej, dowiązania twarde do starego pliku
się rozłączają; bez prawa zapisu do katalogu — zapis w miejscu (nieatomowy, jak dawniej). Pobieranie tworzy
elementy wyłącznie jako nowe, wolną nazwę wybiera system plików. Sesje SSH liczone po gnieździe
ControlMaster, nie po aliasie (rozszerza D50). Dostawca MTP identyfikowany po USB (uzupełnia D51).

### D57 · 2026-10-27 — Przegląd, część 5: bramka, odświeżanie, dziennik, SCP, budowanie
- **Bramka agenta (rozszerza D48):** obrona w głąb po nawigacji — jeśli po wywołaniu agenta aktywna karta
  stoi w zablokowanym katalogu, stan jest przywracany (zamiast deklarowania celów przez każdą komendę).
  Ścieżki agenta ze znakami sterującymi są odrzucane, cel `panel.navigate` liczy jedna funkcja. Wyszukiwanie
  dla agenta nie czyta i nie liczy zablokowanych ścieżek (`rg` z korzeniami rozpisanymi wokół blokad, nie
  globy). Limit wywołań przed bramką, seria odmów agregowana w dzienniku.
- **Wyrażenia regularne:** do 512 znaków, bez zagnieżdżonych kwantyfikatorów i odwołań wstecznych w
  powtarzanej grupie; limit czasu procesora (1 s na plan zmiany nazw, 100 ms na dopasowanie w wyszukiwaniu
  i regułach kolorów — po przekroczeniu wzorzec przestaje pasować). Diff tekstowy do 20 000 różniących się
  wierszy, powyżej porównanie bajtów.
- **Karta (uzupełnia D47/D55):** odświeżenie przywraca kursor tylko, gdy użytkownik go nie przesunął;
  wspina się do katalogu nadrzędnego tylko po „nie istnieje”; odświeżenie pominięte przez nawigację wraca po
  niej. Martwy wpis historii nie obejmuje zapisanego aliasu serwera (po zapisie połączenie wraca w tle);
  sąsiednie duplikaty są scalane. Tytuł karty telefonu też z dostawcy — ręcznie zostaje tylko „⌨”.
- **Kopie do podglądu** z archiwów, telefonów i serwerów są usuwane przy zamknięciu aplikacji (poza F4 i
  plikami otwartymi w innej aplikacji), stare `bifold-view-*` przy starcie po dobie. Elementów nawigowalnych
  spoza dysku lokalnego się nie materializuje.
- **Dziennik (uzupełnia D55):** w pamięci limit partii i 2× limit wpisów, bez partii trwających i najnowszej
  zakończonej; dokładne limity tylko przy starcie. Krok `.missing` liczy się jak wykonany tylko przy
  istniejącym katalogu nadrzędnym (odłączony wolumin zostawia partię cofalną). `edit.undo` przyjmuje `batch`
  (okno dziennika cofa przez rejestr komend).
- **SCP (uzupełnia D56):** edycja pliku-dowiązania zapisuje do celu, „Nadpisz” zastępuje samo dowiązanie
  (jak lokalnie); niezgodny typ zastępowany po wysłaniu (`rm -r -f && mv -f`); zapis w miejscu wg `[ -w ]`
  i po nieudanym `mv`, nie wg tekstu błędu; sesja po rozłączeniu, zapisie lub usunięciu połączenia jest
  unieważniona; wysyłki jednej edycji idą po kolei.
- **Synchronizacja:** `/` nigdy nie jest końcem, wolumin nie jest celem lustra (update na wolumin — kopia
  zapasowa — dozwolony); walidacja wspólna dla komend i okna.
- **⌃U z kartą-terminalem:** terminale w jednym rejestrze okna, sesja przechodzi z kartą do drugiego panelu.
- **Budowanie:** projekt deklaruje Xcode 27 (`xcodeVersion` w `project.yml`); `STRING_CATALOG_GENERATE_SYMBOLS`
  i `ENABLE_USER_SCRIPT_SANDBOXING` świadomie NO. Testy pakietu mają przypięte zależności
  (`Packages/BifoldKit/Package.resolved`, te same wersje co aplikacja). Sparkle zostaje uniwersalny —
  przycięcie do arm64 zmieniałoby podpisane części mechanizmu aktualizacji dla ~0,5 MB.
