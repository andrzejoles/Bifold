# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/).

## [Unreleased]

## [2.3.0] – 2026-10-26

### Poprawione — przegląd kodu, część 3 (bezpieczeństwo agenta AI)
- Agent nie zobaczy w wynikach wyszukiwania (nazwy, treść, duplikaty, zapisane wyszukiwania) plików
  z zablokowanych katalogów (`~/.ssh`, klucze chmur, dane Bifolda) i nie dotrze do nich ścieżkami
  względnymi liczonymi od drugiego panelu ani prefiksem `serwer:`.
- Okno zatwierdzania pokazuje dokładnie to, co zostanie wykonane — zmiana kursora, zaznaczenia lub
  panelu w trakcie nie zmienia celu; widać sesję i jej katalog, podejrzane znaki w nazwach jako kody.
- Agent nie skopiuje, nie przeniesie, nie spakuje ani nie zsynchronizuje katalogu zawierającego
  zablokowane ścieżki; synchronizacja na serwer tylko do odczytu jest blokowana także dla zapisanych zadań.
- Błędne argumenty od agenta nie zamykają aplikacji; zbyt duża odpowiedź daje czytelny błąd; inny
  program nie zamknie Bifolda przez gniazdo agenta; druga kopia Bifolda nie przejmuje połączeń agentów.
- Dziennik agentów nie zapisuje treści czytanych plików i zapisuje każde wywołanie.
- Agent nie zamknie karty z terminalem SSH ani nie rozłączy serwera z otwartym terminalem lub edycją.
### Poprawione — operacje na plikach
- Zmiana samej wielkości liter (F6 `Foo.txt` → `foo.txt` z „Nadpisz”) zmienia nazwę zamiast przenosić
  plik do Kosza; F5 katalogu pod nazwą różniącą się wielkością liter nie kopiuje go w siebie.
- Kopiowanie plików zablokowanych i o bardzo długich nazwach działa i nie zostawia plików tymczasowych;
  „Nadpisz” nie usuwa trwale pliku z powodu przejściowego błędu Kosza.
- Zmiana nazw wielu plików obsługuje łańcuchy (1→2, 2→3…); po błędzie nic nie zostaje pod ukrytą nazwą.
- Cmd+Z nie cofa operacji, która jeszcze trwa; cofanie dużych operacji nie zamraża okna; częściowo
  cofnięta operacja zostaje do dokończenia; dziennik nie rośnie bez końca i nie ginie po błędzie zapisu.
- „Rozpakuj archiwa” z nadpisaniem przenosi zastępowane pliki do Kosza (cofalne); przerwane pakowanie
  nie zostawia niekompletnego archiwum; podgląd pliku z archiwum nie wczytuje go całego do pamięci.
- Dzielenie pliku nie nadpisuje istniejących części; duplikaty nie pokazują pliku jako własnego duplikatu;
  anulowanie wyszukiwania w treści działa od razu, wyszukiwanie po masce jest szybsze.
### Poprawione — serwery i telefony
- Plik o spreparowanej nazwie na serwerze SCP nie zamyka już aplikacji.
- „Nadpisz” przy wysyłaniu katalogu przez SCP scala katalogi (pliki, których nie wysyłasz, zostają);
  przy istniejących plikach Bifold pyta jak przy kopiowaniu lokalnym.
- SFTP/FTP/WebDAV: zmiana nazwy, nowy plik i nowy katalog nie nadpisują po cichu istniejących elementów.
- Pobieranie katalogu z SCP nie wchodzi w dowiązania (`link -> ..`); „README” i „Readme” nie nadpisują się.
- Pliki ze starszego macOS (polskie znaki w innej postaci Unicode) dają się otwierać, kopiować i usuwać.
- Wstrzymanie jednego transferu rclone nie zatrzymuje pozostałych; pliki pobrane z serwerów i telefonów
  mają oznaczenie „pobrane z internetu” (Gatekeeper).
- Anulowanie kopiowania z iPhone’a działa od razu; dwa iPhone’y tego samego modelu się nie mylą; F3 na
  pliku z telefonu nie zamyka aplikacji.
- Terminal i pliki tego samego serwera korzystają z jednego połączenia; komunikaty `.bashrc` nie psują
  ścieżek; edycja pliku na serwerze wysyła ostatni zapis; Bifold nie zostawia katalogów w `/tmp` ani
  działającego rclone po awarii.
- Pomocnik administratora odrzuca operacje na katalogach systemowych najwyższego poziomu i ich
  przodkach; okno hasła pokazuje ścieżki.
### Poprawione — interfejs
- W widoku kolumn można pisać w oknach dialogowych, Ustawieniach, wyszukiwaniu i palecie komend; widok
  kolumn nie zawiesza okna przy dużych katalogach, a poza dyskiem lokalnym pokazuje listę szczegółów.
- Dolny terminal dostaje Ctrl+W, Ctrl+R, F3–F8 itd. (nie wykonują operacji na plikach); w terminalu SSH
  w karcie Ctrl+Tab przenosi klawiaturę do drugiego panelu, a ⌘W zamyka kartę także w profilu TC.
- W polach tekstowych ⌘Z cofa pisanie (nie operację na plikach), ⌘A zaznacza tekst; w podglądzie i
  Ustawieniach ⌘W zamyka okno, ⌘F szuka; nowe pozycje menu Cofnij, Ponów, Znajdź…, Zamknij okno.
- Tło reguł kolorów jest rysowane; ⌘+klik zaznacza także w miniaturach; zmiana czcionki dopasowuje
  wysokość wierszy; kolory nadążają za zmianą motywu; tło oznaczonych wierszy odświeża się od razu.
- Kolejka: błędy zadań nie znikają po 4 s, działające zadania są zawsze widoczne.
- Drzewo katalogów pokazuje nowe katalogi, pliki ukryte i nowe woluminy bez zamrażania okna.
- Tytuł karty nadąża za katalogiem; ⌃U zamienia całe karty; nieudana „Nowa karta” nie zostawia pustej
  karty; F5/F6/⌥F9 przy drugim panelu w archiwum, wynikach lub na telefonie nie podsuwają fałszywego
  katalogu lokalnego.
- Skróty przechwytywane przez macOS zastąpione: Spotlight ⌃⌥F, duplikaty ⌃⌥D; sortowanie w profilu TC
  także ⌃⌘1–5; skrót przy pozycji menu nie zmienia się między uruchomieniami.
- Linia poleceń: `cd /tmp && make` wykonuje się w terminalu; po zmianie języka aplikacja nie uruchomi się
  sama, jeśli zamknięcie anulowano; „O programie” pokazuje prawa autorskie z konfiguracji marki.
### Zmienione — budowanie
- Budowanie tylko dla Apple Silicon (bez ostrzeżenia o celu, Release szybszy); `gen-strings.py` nie
  zmienia katalogu tłumaczeń bez potrzeby; `signing.sh` bez haseł w argumentach procesów; licencje tylko
  dołączonych bibliotek; usunięty nieużywany `make perf-fixture`; test wydajności nie blokuje innych testów.

## [2.2.0] – 2026-10-26

### Poprawione — miniatury
- Pusty plik w widoku miniatur pokazywał puste miejsce (podgląd QuickLook to biała strona bez treści) —
  teraz ikona typu pliku; jednolity, pusty podgląd też zostaje zastąpiony ikoną.
- Miniatury dokumentów w ramce z zagiętym rogiem, jak w Finderze (biała strona tekstu ginęła na białym tle).

## [2.1.0] – 2026-10-26

### Poprawione — przegląd kodu, część 2
- Archiwa: wpisy ze ścieżką `../…` (spreparowane archiwum) są pomijane — przy kopiowaniu z archiwum
  wskazywałyby istniejący plik poza katalogiem tymczasowym; archiwa tar z „.” (`./kat/…`) pokazują
  `kat` zamiast folderu „.”, a kopiowanie z nich działa.
- Serwery: nazwy z wyjścia `ls` (SCP) i z rclone z `/`, `..` albo znakami sterującymi są pomijane —
  pobieranie katalogu z SCP mogło zapisać plik poza katalogiem docelowym.
- Pomocnik administratora: lista katalogów zabronionych bez rozróżniania wielkości liter
  (`/private/etc/SUDOERS` omijało ją na APFS).
- Miniatury: długa nazwa w dwóch liniach z „…” na końcu drugiej (wcześniej ucięta bez wielokropka).
- `make unregister` czyta bundle id z `Config/Brand.xcconfig`.

## [2.0.0] – 2026-10-26

### Poprawione — przegląd kodu
- Długa nazwa pliku w widoku szczegółów (i w widoku skróconym) zawijała się do drugiej linii w wierszu
  o stałej wysokości: tekst z atrybutami bez stylu akapitu pomijał obcinanie z pola. Teraz jedna linia
  z „…” w środku nazwy, pełna nazwa w podpowiedzi po najechaniu.
- Telefony z Androidem: nazwy plików z telefonu z `/`, `..` albo znakami sterującymi są pomijane (trafiały
  do ścieżek lokalnych przy kopiowaniu i do poleceń pomocnika `bifold-mtp`); pomocnik odrzuca też takie
  ścieżki docelowe i zamienia niepoprawne UTF-8 na „�” zamiast psuć cały listing.
- Zamknięcie telefonu w trakcie kopiowania nie czeka na koniec pobierania (przerywa je).
- Narzędzia urządzeń (`afcclient`, `idevice_id`, `bifold-mtp detect`) mają limit czasu — zawieszone
  narzędzie nie blokuje już wątku na zawsze.
- Bez libmtp z Homebrew komunikat „Nie wykryto telefonu” podpowiada `brew install libmtp`.
- Panel agenta: „Zakończ” dobija grupę procesów CLI także wtedy, gdy powłoka zakończyła się pierwsza.
- Zapis sesji z panelem samych kart-terminali — karta w katalogu domowym zamiast serwera.
- Terminal SSH: `LANG` z ustawień systemu zamiast zawsze `pl_PL.UTF-8`; argument `side` sprawdzany.
- Możliwe zakleszczenie przy kilku równoczesnych operacjach na archiwach (7zz) i przez SSH: wątki czytające
  wyjście procesów czekały na pulę GCD, której wątki były zajęte — teraz mają własne wątki.
- Wolno wczytujący się katalog (serwer, odświeżenie przy obciążeniu) nadpisywał kartę, jeśli w międzyczasie
  przeszło się gdzie indziej — karta pokazywała poprzedni katalog, a kursor wracał na początek. Teraz
  wygrywa ostatnia nawigacja.
- Dziennik połączeń agenta: odmowa jest zapisywana przed wysłaniem odpowiedzi (bez wyścigu); zatrzymanie
  agenta zapisuje zaległe wpisy dziennika na dysk.
- Testy: `Workspace` bez cyklu referencji z `RemoteManager` (porzucone obiekty odświeżały w kółko
  `$TMPDIR` i zawieszały `make test`), katalogi `bifold-tests-ssh-*` usuwane po teście, testy SCP nie
  porzucają już swojego katalogu tymczasowego (zapis połączeń odtwarzał go po usunięciu).
- Budowanie bez ostrzeżeń kompilatora; kroki skryptów z wejściami i wyjściami (bez uruchamiania przy
  każdym budowaniu).
### Zmienione
- SwiftTerm 1.99.1, Sparkle 2.10.1, swift-log 1.16.2, swift-collections 1.7.4.

## [1.9.0] – 2026-10-20

### Zmienione — każda karta ma swoją „maszynę”
- Karta jest związana z dyskiem lokalnym, serwerem albo telefonem, a nie cały panel. Otwarcie połączenia
  (Menedżer połączeń, „Otwórz połączenie…”, ścieżka `alias:/…`) i telefonu (Ctrl+Alt+P) otwiera nową kartę
  zamiast podmieniać bieżącą; ten sam serwer w aktywnej karcie — ta sama karta.
- Karta-terminal SSH zostaje terminalem: nowa karta z niej (Ctrl+T) to pliki lokalne (katalog domowy),
  a katalogi otwierane z niej (drzewo, dom, „Przejdź do katalogu”) trafiają do nowej karty. Kilka terminali
  naraz — każdy w swojej karcie, do tego samego albo różnych serwerów.
- „Rozłącz” zamyka karty serwera/telefonu (ostatnia karta panelu wraca do katalogu domowego).
### Dodane
- Wybór dysku w karcie jak w TC: przycisk z nazwą dysku przed ścieżką (oraz Alt+F1 / ⌘D) — woluminy
  z wolnym miejscem (dysk wewnętrzny, USB, udziały), katalog domowy, telefon, zapisane połączenia, Menedżer
  połączeń i wysuwanie woluminów.
- Typ terminala (TERM) w ustawieniach połączenia SFTP/SCP (np. `xterm` dla starego AIX); domyślnie
  `xterm-256color`.

## [1.8.0] – 2026-10-19

- Po „Zezwól” Samsung łączy się z USB od nowa, a sesja otwarta wcześniej nigdy nie widziała nośników —
  Bifold używał jej dalej (pusty panel). Teraz brak nośników albo zerwana sesja = nowa sesja.
- Bez zgody karta przechodzi na telefon z komunikatem; Ctrl+R po „Zezwól” ponawia próbę na telefonie.
### Poprawione — telefony z Androidem

## [1.7.0] – 2026-10-19

### Poprawione — telefony z Androidem
- Pusty panel po otwarciu telefonu: narzędzia mtp-files/mtp-folders wczytywały cały telefon naraz (minuty
  przy tysiącach zdjęć). Nowy pomocnik `bifold-mtp` (libmtp) czyta folder po folderze w jednej sesji MTP.
- Telefon bez „Zezwól” (dostęp do danych) na ekranie: komunikat z instrukcją zamiast pustego panelu;
  sesja zostaje, po zgodzie wystarczy odświeżyć.
- Telefon da się zamknąć: ⏏ na pasku ścieżki i „Rozłącz” (Ctrl+Shift+F) zwalniają telefon.

## [1.6.0] – 2026-10-19

### Poprawione — panel agenta
- „Zakończ” nie kończyło CLI, które przechwytuje SIGTERM, i zostawiało otwarty panel. Teraz SIGHUP do całej
  grupy procesów (jak zamknięcie okna terminala), po 2 s SIGKILL; bez działających sesji panel się chowa
  (zakończona sesja zostaje na liście z dziennikiem i cofaniem — Ctrl+Alt+0).

## [1.5.0] – 2026-10-19

### Dodane — terminal SSH w panelu
- Otwarcie połączenia SFTP/SCP (np. z Menedżera połączeń) pokazuje pliki serwera w aktywnym panelu, a w drugim
  panelu kartę-terminal zalogowaną na ten serwer — przez to samo połączenie, bez ponownego hasła, w katalogu
  z panelu (ustawienie „Przy otwarciu: terminal SSH w drugim panelu”, domyślnie włączone).
- „Terminal SSH…” (menu Sieć, paleta, przycisk na pasku ścieżki, Menedżer połączeń).
- W terminalu wszystkie klawisze bez Cmd idą do serwera (F-klawisze, Tab, Esc); Ctrl+Tab — drugi panel,
  ⌘W — zamknięcie karty; rozłączenie zamyka terminale serwera.

### Poprawione
- Serwery i telefony pokazywały „0 B wolne”.

## [1.4.0] – 2026-10-18

### Dodane — rozłączanie
- „Rozłącz” (menu Sieć, paleta, Ctrl+Shift+F jak w Total Commanderze, ⌃⌘K w profilu Cmd, przycisk ⏏ na pasku
  ścieżki, Menedżer połączeń): zamyka sesję SSH/rclone, karty z tym serwerem wracają do katalogu domowego.
- Pasek ścieżki pokazuje `alias:/katalog` dla serwerów (wcześniej zostawała ostatnia ścieżka lokalna).

### Poprawione — SCP/SFTP
- Pierwsze połączenie przez rclone (SFTP, FTP…) „zapominało” otwarte połączenia SCP; kolejne wejście na serwer
  SCP logowało się od nowa i zamykało wspólne połączenie główne.

## [1.3.0] – 2026-10-18

### Poprawione — SCP/SFTP
- Połączenie SCP (i zapamiętanie klucza serwera SFTP) kończyło się błędem „keyword controlpath extra arguments
  at end of line”: ścieżka gniazda w „~/Library/Application Support” ma spację, a `ssh` rozcinał na niej opcję.

## [1.2.0] – 2026-10-17

### Dodane — języki
- Interfejs po angielsku, niemiecku, hiszpańsku i ukraińsku (obok polskiego), wybór w Ustawieniach.
- Eksport pliku do tłumaczenia (JSON dla tłumacza lub AI) i import gotowego tłumaczenia, jak w CantatePresenter.
- Opisy uprawnień macOS (Biurko, Dokumenty…) w tych samych językach.
- 18 komunikatów miało w katalogu tłumaczeń błędne klucze i nie dało się ich przetłumaczyć.
- W Launchpadzie i „Otwórz za pomocą” widać tylko jedną kopię Bifolda.
### Poprawione

## [1.1.0] – 2026-10-17

### Dodane — wydania i serwery
- **SCP** (klasyczny protokół, `scp -O`) dla serwerów bez SFTP: listing, kopiowanie w obie strony,
  nowy katalog, zmiana nazwy, usuwanie, podgląd i edycja; kodowanie nazw UTF-8 lub ISO-8859-2.
- **Zgodność ze starymi serwerami SSH** (AIX 6.1 i podobne) dla SCP i SFTP.
- **Automatyczne aktualizacje** (Sparkle, podpis EdDSA), menu „Sprawdź uaktualnienia…”.
- **Instalatory** DMG i PKG (`make installer`), skrypt wydania na GitHubie (`scripts/release.sh`).
- Wersja z historii gita jak w CantatePresenter; autor w oknie „O programie”; licencja MIT.
- Stały podpis aplikacji (zgody macOS zostają po aktualizacji).

### Poprawione
- SFTP: klucz serwera jest sprawdzany (wcześniej rclone przyjmował każdy).
- SFTP: absolutny katalog startowy (np. `/var/log`) był liczony od katalogu domowego.
- `connections.json` i pozostałe pliki ustawień z uprawnieniami 0600.

### Dodane — Etap 7 (urządzenia i uprawnienia administratora)
- Telefony z Androidem (MTP, libmtp) i iPhone’y (AFC, libimobiledevice) w panelu (Ctrl+Alt+P), tylko do odczytu,
  kopiowanie na dysk; opis ograniczeń iOS (DCIM i katalogi aplikacji z udostępnianiem plików).
- Pomocnik administratora: demon XPC przez SMAppService, wąska lista operacji, autoryzacja każdej
  operacji hasłem administratora; komendy „Jako administrator: …” (niedostępne dla agenta).
- Narzędzia MCP: device_list, device_open.

### Dodane — Etap 6 (porównywanie i synchronizacja)
- Porównanie plików: tekst (różnice wierszy obok siebie, Myers), binarne (pierwsza różnica, liczba bajtów).
- Porównanie katalogów (Shift+F2): zaznacza w obu panelach pliki unikalne i nowsze (lub różne treścią).
- Synchronizacja (Ctrl+Alt+S) lokalna i z serwerami: lustro, aktualizacja, dwukierunkowa; zawsze
  podgląd „na sucho” z możliwością odznaczenia pozycji; zapisane zadania uruchamiane jednym kliknięciem.
- Narzędzia MCP: compare_files, compare_dirs, sync_preview, sync_run, sync_job_save/list/run.

### Dodane — Etap 5 (sieć i serwery przez rclone)
- rclone `rcd` na gnieździe Unix z konfiguracją w pamięci; połączenia SFTP (klucze, agent SSH), FTP/FTPS,
  WebDAV, SMB, Google Drive, Dropbox, OneDrive (OAuth przez `rclone authorize` w terminalu).
- Menedżer połączeń (Ctrl+F / Cmd+K): aliasy, hasła i tokeny w Keychain, test połączenia.
- Serwery w panelach (`alias:/ścieżka`): przeglądanie, kopiowanie i przenoszenie lokalny⇄zdalny
  i zdalny⇄zdalny z postępem, limitem i anulowaniem, katalogi, zmiana nazw, usuwanie z potwierdzeniem.
- Edycja plików zdalnych (pobranie, edytor, wysyłka po zapisie), wyszukiwanie na serwerach,
  montowanie SMB/NFS przez NetFS.
- Agent: remote_connections/open/list/read/search tylko po aliasie; zasada najmniejszego poziomu
  między zasobami (testy z prawdziwymi serwerami `rclone serve sftp/ftp/webdav`).

### Dodane — Etap 4 (archiwa)
- Archiwum jak katalog (Enter): ZIP, 7z, RAR, TAR, GZ, BZ2, XZ, ISO i inne obsługiwane przez 7zz;
  „..” wraca do katalogu z archiwum; F3/Quick Look/F4 na plikach z archiwum; kopiowanie z archiwum (F5).
- Pakowanie (Alt+F5): ZIP, 7z, TAR, TAR.GZ/BZ2/XZ, GZ/BZ2/XZ, poziom kompresji, archiwa wieloczęściowe,
  hasło (ZIP/7z, 7z z szyfrowaniem nazw) — hasło podaje tylko użytkownik.
- Rozpakowywanie (Alt+F9) do podkatalogów, test archiwów, wyszukiwanie nazw w archiwach.
- Narzędzia MCP: archive_create, archive_extract, archive_list, archive_test (bez haseł).

### Dodane — Etap 3 (wyszukiwanie, zmiana nazw, narzędzia plikowe)
- Wyszukiwanie (Alt+F7): maska/regex nazwy, treść przez ripgrep (kodowania, w tym windows-1250),
  daty, rozmiary, typ, ukryte; wyniki na żywo, „Do panelu”, „Przejdź do pliku”, zapisane wyszukiwania.
- Spotlight (`NSMetadataQuery`), duplikaty (nazwa / nazwa+rozmiar / treść SHA-256).
- Zmiana nazw wielu plików (Ctrl+M) z podglądem: maski TC, licznik, daty, EXIF, tagi multimediów,
  znajdź-zamień (regex), wielkość liter nazwy i rozszerzenia; cofanie także zamian a↔b.
- Sumy MD5/SHA-1/SHA-256 (tworzenie i weryfikacja), dzielenie i łączenie plików z kontrolą SHA-256.
- Narzędzia MCP: search, spotlight_search, saved_search_*, find_duplicates, multi_rename, checksum,
  checksum_verify, split_file, join_files.

### Naprawione
- Zawieszanie startu na folderach w chmurze (tagi czytane w tle), zakleszczenie obserwatora katalogów,
  okno zatwierdzania bez przycisku domyślnego.

### Dodane — Etap 2 (API agentów)
- Most `bifold-mcp` (stdio ⇄ gniazdo Unix `0600` w katalogu `0700`, bez portów TCP) w pakiecie aplikacji.
- Uwierzytelnianie połączenia: UID rozmówcy, ramka `hello` z 256-bitowym tokenem (porównanie w stałym
  czasie, limit 5 s), most musi być potomkiem procesu CLI sesji; token unieważniany po końcu sesji.
- Serwer MCP (swift-sdk) z ~37 narzędziami odwzorowanymi na rejestr komend + `run_command`; narzędzia
  z poziomem „Brak” niewidoczne; zasada najmniejszego poziomu; lista zablokowanych ścieżek (z `..`,
  dowiązaniami, wielkością liter); limit rozmiaru odczytu, binaria jako metadane/hex; limit wywołań.
- Okno zatwierdzania z podglądem skutków (lista operacji, liczba plików, rozmiar, konflikty).
- Panel agenta: CLI w terminalu SwiftTerm + panel aktywności; uruchamianie Claude Code, Codex, Grok,
  Antigravity (Ctrl+Alt+1…4) w katalogu aktywnego panelu; tryb ścisły domyślnie.
- Dziennik JSONL wywołań (`agent-logs/`), przeglądarka dziennika, „Cofnij sesję agenta”.
- Testy: 19 testów bezpieczeństwa/polityki + opcjonalny test E2E z prawdziwymi CLI (`BIFOLD_E2E_AGENTS=1`).

### Dodane — Etap 1 (rdzeń lokalny)
- Dokumentacja startowa: architektura, model zagrożeń, plan Etapu 1, decyzje, biblioteki.
- `BifoldCore`: `FileSystemProvider`, `LocalFS` (getattrlistbulk, FSEvents), kopiowanie i przenoszenie
  przez `copyfile(3)` z pauzą, limitem prędkości, anulowaniem i konfliktami, kolejka zadań, dziennik
  operacji (JSONL) z cofaniem i wykrywaniem konfliktów, maski TC, reguły kolorów (JSON), kodowania.
- `BifoldWorkspace`: model stanu (panele, karty, zaznaczenie, filtr), rejestr ~80 komend z poziomami
  agenta i podglądem skutków, profile skrótów TC i Cmd, zapis sesji.
- Aplikacja: dwa panele z kartami, widoki szczegóły/lista skrócona/miniatury/kolumny, drzewo, szybkie
  wyszukiwanie i filtr, pasek stanu, podgląd F3 (tekst/hex HexFiend/obraz), Quick Look, panel podglądu,
  edytor F4 (Nextpad++), linia poleceń i terminal SwiftTerm, kolejka operacji, paleta komend,
  ustawienia, dziennik operacji, woluminy, tagi, atrybuty, Udostępnij, Otwórz za pomocą.
