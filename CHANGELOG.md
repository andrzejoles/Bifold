# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/).

## [Unreleased]

### Poprawione — telefony z Androidem
- Pusty panel po otwarciu telefonu: narzędzia mtp-files/mtp-folders wczytywały cały telefon naraz (minuty
  przy tysiącach zdjęć). Nowy pomocnik `bifold-mtp` (libmtp) czyta folder po folderze w jednej sesji MTP.
- Telefon bez „Zezwól” (dostęp do danych) na ekranie: komunikat z instrukcją zamiast pustego panelu;
  sesja zostaje, po zgodzie wystarczy odświeżyć.
- Telefon da się zamknąć: ⏏ na pasku ścieżki i „Rozłącz” (Ctrl+Shift+F) zwalniają telefon.

### Poprawione — panel agenta
- „Zakończ” nie kończyło CLI, które przechwytuje SIGTERM, i zostawiało otwarty panel. Teraz SIGHUP do całej
  grupy procesów (jak zamknięcie okna terminala), po 2 s SIGKILL; bez działających sesji panel się chowa
  (zakończona sesja zostaje na liście z dziennikiem i cofaniem — Ctrl+Alt+0).

### Dodane — terminal SSH w panelu
- Otwarcie połączenia SFTP/SCP (np. z Menedżera połączeń) pokazuje pliki serwera w aktywnym panelu, a w drugim
  panelu kartę-terminal zalogowaną na ten serwer — przez to samo połączenie, bez ponownego hasła, w katalogu
  z panelu (ustawienie „Przy otwarciu: terminal SSH w drugim panelu”, domyślnie włączone).
- „Terminal SSH…” (menu Sieć, paleta, przycisk na pasku ścieżki, Menedżer połączeń).
- W terminalu wszystkie klawisze bez Cmd idą do serwera (F-klawisze, Tab, Esc); Ctrl+Tab — drugi panel,
  ⌘W — zamknięcie karty; rozłączenie zamyka terminale serwera.

### Poprawione
- Serwery i telefony pokazywały „0 B wolne”.

### Dodane — rozłączanie
- „Rozłącz” (menu Sieć, paleta, Ctrl+Shift+F jak w Total Commanderze, ⌃⌘K w profilu Cmd, przycisk ⏏ na pasku
  ścieżki, Menedżer połączeń): zamyka sesję SSH/rclone, karty z tym serwerem wracają do katalogu domowego.
- Pasek ścieżki pokazuje `alias:/katalog` dla serwerów (wcześniej zostawała ostatnia ścieżka lokalna).

### Poprawione — SCP/SFTP
- Pierwsze połączenie przez rclone (SFTP, FTP…) „zapominało” otwarte połączenia SCP; kolejne wejście na serwer
  SCP logowało się od nowa i zamykało wspólne połączenie główne.
- Połączenie SCP (i zapamiętanie klucza serwera SFTP) kończyło się błędem „keyword controlpath extra arguments
  at end of line”: ścieżka gniazda w „~/Library/Application Support” ma spację, a `ssh` rozcinał na niej opcję.

### Dodane — języki
- Interfejs po angielsku, niemiecku, hiszpańsku i ukraińsku (obok polskiego), wybór w Ustawieniach.
- Eksport pliku do tłumaczenia (JSON dla tłumacza lub AI) i import gotowego tłumaczenia, jak w CantatePresenter.
- Opisy uprawnień macOS (Biurko, Dokumenty…) w tych samych językach.

### Poprawione
- 18 komunikatów miało w katalogu tłumaczeń błędne klucze i nie dało się ich przetłumaczyć.
- W Launchpadzie i „Otwórz za pomocą” widać tylko jedną kopię Bifolda.

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
