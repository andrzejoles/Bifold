# Prompt: dwupanelowy menedżer plików dla macOS 27 z API dla agentów AI

> Prompt dla agenta programistycznego (Claude Code, Codex CLI lub podobnego). Wklej całość jako pierwszą wiadomość w pustym katalogu projektu.

---

## 0. Twoja rola i sposób pracy

Jesteś doświadczonym programistą macOS (Swift, AppKit). Budujesz dla mnie natywny, dwupanelowy menedżer plików w stylu Total Commandera, obsługiwany głównie klawiaturą. Ma on wbudowane, bezpieczne API, przez które agenci AI uruchomieni z aplikacji mogą czytać jej stan i sterować nią.

Zasady pracy:

1. **Najpierw plan, potem kod.** Zanim napiszesz pierwszą linię kodu, przeczytaj cały dokument. Potem przygotuj `docs/ARCHITECTURE.md` (moduły, przepływ danych, model uprawnień agenta) i szczegółowy plan Etapu 1. Pokaż mi je i poczekaj na akceptację.
2. **Pracuj etapami (sekcja 6).** Każdy etap kończy się aplikacją, której da się używać na co dzień. Nie zaczynaj kolejnego etapu, dopóki poprzedni nie spełnia kryteriów odbioru i nie potwierdzę, że działa.
3. **Gotowe, sprawdzone biblioteki zamiast własnych implementacji** (sekcja 3). Nie pisz własnej kryptografii, obsługi SSH, FTP ani formatów archiwów. Jeśli chcesz użyć innej biblioteki niż wskazana albo napisać coś samodzielnie, najpierw uzasadnij to w `docs/DECISIONS.md` i zapytaj.
4. **Pytaj, gdy coś jest niejasne** albo gdy dwa wymagania sobie przeczą. Nie zgaduj w sprawach bezpieczeństwa.
5. Na bieżąco prowadź `docs/DECISIONS.md` (decyzje i ich powody), `docs/THIRD_PARTY.md` (biblioteki, wersje, licencje) i `CHANGELOG.md`.
6. Każda funkcja ma testy: jednostkowe dla logiki (operacje, maski nazw, reguły kolorów, polityka uprawnień), integracyjne dla API agenta i bezpieczeństwa.

---

## 1. Kontekst

- **Użytkownik:** tylko ja, na własnym MacBooku Pro (Apple Silicon M5 Pro, macOS 27). Bez dystrybucji, bez Mac App Store i bez notaryzacji. Wystarczy budowanie lokalne w Xcode z podpisem „Sign to Run Locally” lub darmowym zespołem osobistym.
- **Wzorzec:** Total Commander (logika, skróty, funkcje). Inspiracje z ForkLift 4 (wygoda w macOS, sieć) i Commander One (archiwa, terminal).
- **Nazwa robocza:** `Bifold`, bundle id `local.aoles.bifold`. Nazwę zmienię później, więc trzymaj ją w jednym miejscu.
- **Język interfejsu:** polski, wszystkie teksty w String Catalog (`Localizable.xcstrings`), żeby dało się dodać inne języki.
- **Uprawnienia systemowe:** aplikacja działa bez sandboxa i potrzebuje pełnego dostępu do dysku (Full Disk Access). Przy pierwszym uruchomieniu wykryj jego brak i pokaż instrukcję, jak go nadać.

---

## 2. Stos technologiczny

| Obszar | Wybór |
|---|---|
| Język | Swift 6, tryb ścisłej współbieżności (strict concurrency) |
| Interfejs | **AppKit** dla list plików i okna głównego (`NSTableView`, `NSOutlineView`, `NSBrowser`, `NSCollectionView`). SwiftUI tylko dla ustawień i prostych okien dialogowych |
| Platforma | macOS 27 jako minimum, tylko arm64 |
| Projekt | Xcode + Swift Package Manager. Logika w pakietach SPM testowalnych bez interfejsu |
| Testy | Swift Testing / XCTest |
| Listowanie katalogów | `getattrlistbulk` lub `FileManager` z prefetchem kluczy zasobów. Obserwowanie zmian: FSEvents / `DispatchSource` |
| Wydajność | Katalog ze 100 000 plików: pierwsze wyświetlenie poniżej 1 s, płynne przewijanie, sortowanie i filtrowanie w tle |

---

## 3. Biblioteki i narzędzia zewnętrzne

Narzędzia CLI instaluję przez Homebrew. Aplikacja szuka ich w `/opt/homebrew/bin`, ścieżki da się zmienić w ustawieniach. Brak narzędzia wyłącza tylko zależne od niego funkcje i pokazuje czytelny komunikat.

| Obszar | Biblioteka / narzędzie | Uwagi |
|---|---|---|
| Operacje na plikach | `FileManager`, `copyfile(3)` | Zachowuj atrybuty rozszerzone, ACL i daty |
| Kosz | `NSWorkspace.recycle` | Zapamiętuj nowe ścieżki w Koszu (potrzebne do cofania) |
| Cofanie | `NSUndoManager` + własny dziennik operacji | Patrz sekcja 5.6 |
| Sumy kontrolne | CryptoKit | MD5 (`Insecure.MD5`), SHA-1, SHA-256 |
| Wyszukiwanie w treści | **ripgrep** (`rg`, Homebrew) jako proces | Wyniki w formacie `--json` |
| Spotlight | `NSMetadataQuery` | |
| Archiwa | **7-Zip** (`7zz`, Homebrew `sevenzip`) jako jeden backend | ZIP, TAR, GZ, BZ2, XZ, 7z, rozpakowywanie RAR, archiwa wieloczęściowe, hasła. `7zz l -slt` do listowania. libarchive tylko wtedy, gdy przeglądanie przez `7zz` okaże się za wolne |
| Serwery i chmury | **rclone** jako jeden backend dla wszystkich zdalnych systemów plików | `rclone rcd` (API zdalnego sterowania) na gnieździe Unix lub na localhost z losowym hasłem. Patrz sekcja 5.5 |
| Udziały SMB/NFS | NetFS (`NetFSMountURLAsync`) + zwykłe operacje na zamontowanym woluminie | |
| Hasła | Security.framework (Keychain) | Nigdy jawnym tekstem w plikach ani w konfiguracji rclone |
| Podgląd hex | HexFiend.framework | |
| Quick Look | QuickLookUI (`QLPreviewPanel`, `QLPreviewView`) | |
| Porównanie plików | `CollectionDifference` z biblioteki standardowej Swift (algorytm Myersa) dla tekstu, własne porównanie blokowe dla plików binarnych | |
| Synchronizacja | rclone (`sync`, `copy`, `check`, `bisync`, zawsze najpierw `--dry-run` do podglądu) | Też dla katalogów lokalnych |
| Terminal | **SwiftTerm** | Dla wbudowanego terminala i dla paneli agentów |
| Metadane do nazw | ImageIO (EXIF), AVFoundation (tagi multimediów) | |
| Dyski | DiskArbitration + `URLResourceValues` | |
| Tagi Findera | `URLResourceValues.tagNames` | |
| Udostępnianie | `NSSharingServicePicker`, `NSWorkspace` (Otwórz za pomocą) | |
| Android (MTP) | libmtp (Homebrew) | |
| iPhone | libimobiledevice (Homebrew), usługa AFC | Dostęp tylko do zdjęć i katalogów aplikacji z udostępnianiem plików. Opisz to ograniczenie w interfejsie |
| Uprawnienia administratora | `SMAppService` + pomocnik XPC z wąską listą operacji | Każda operacja wymaga autoryzacji (Authorization Services) |
| Agenci AI | **MCP Swift SDK** (`modelcontextprotocol/swift-sdk`) | Patrz sekcja 5 |

Licencje GPL/LGPL są dopuszczalne (użytek prywatny), ale i tak zapisuj je w `docs/THIRD_PARTY.md`.

---

## 4. Architektura: zasady, których nie wolno łamać

1. **Wirtualny system plików.** Każdy panel pokazuje zawartość przez protokół `FileSystemProvider` z implementacjami `LocalFS`, `ArchiveFS` (7zz), `RemoteFS` (rclone) i `DeviceFS` (MTP/AFC). Panele, operacje, wyszukiwanie i API agenta działają ponad tym protokołem, a nie na konkretnej implementacji.
2. **Rejestr komend.** Każda czynność w aplikacji to komenda w jednym rejestrze: identyfikator, nazwa, domyślny skrót, parametry, funkcja wykonująca, **poziom dostępu agenta** i opis skutków (do podglądu przed wykonaniem). Klawiatura, menu, paleta komend i API agenta wywołują dokładnie te same komendy. Ta zasada obowiązuje od Etapu 1, mimo że API pojawia się dopiero w Etapie 2.
3. **Kolejka operacji.** Kopiowanie, przenoszenie, usuwanie, pakowanie i synchronizacja trafiają do kolejki działającej w tle: z postępem, pauzą, wznowieniem, anulowaniem, limitem prędkości i rozwiązywaniem konfliktów (nadpisz, pomiń, zmień nazwę, dla wszystkich).
4. **Dziennik operacji.** Każda operacja zmieniająca pliki zapisuje się z danymi potrzebnymi do jej odwrócenia (sekcja 5.6).
5. **Stan aplikacji jako model.** Panele, karty, ścieżki, zaznaczenie, widok i filtr tworzą jeden model, z którego czytają interfejs i API. Interfejs niczego nie przechowuje tylko u siebie.

---

## 5. Integracja z agentami AI

### 5.1 Obsługiwani agenci

Aplikacja uruchamia **oficjalne CLI** jako osobne procesy. Logowanie i subskrypcje obsługuje samo CLI, a aplikacja nigdy nie widzi ich tokenów ani nie wywołuje API dostawców bezpośrednio.

| Agent | Polecenie | Tryb bez interfejsu | Rejestracja MCP |
|---|---|---|---|
| Claude Code | `claude` | `-p` | `--mcp-config <plik>` (konfiguracja na sesję, bez zmian w globalnych ustawieniach) |
| Codex CLI | `codex` | `codex exec` | `-c mcp_servers.<nazwa>.command=...` lub `codex mcp add` |
| Grok CLI | `grok` | `grok agent`, `-p` | `grok mcp` |
| Antigravity | `agy` | `-p` / `--print` | `agy mcp add` |

Dla każdego CLI ustal na podstawie jego `--help`, jak podać serwer MCP **tylko dla jednej sesji**. Jeśli się nie da, zarejestruj go trwale dopiero za moją zgodą. To bezpieczne, bo bez tokenu sesji most i tak odrzuci każde połączenie (5.3).

### 5.2 Panel agenta

- Agenta uruchamiam z menu lub skrótem: wybieram jednego z czterech, a jego katalogiem roboczym jest katalog aktywnego panelu.
- Agent działa w **panelu terminala (SwiftTerm) wewnątrz okna aplikacji**, z natywnym interfejsem swojego CLI. To jest „panel czatu” w Etapie 2. Natywny czat przez `stream-json` lub `--output-format json` może dojść później.
- Obok panelu terminala jest **panel aktywności**: na żywo pokazuje każde wywołanie API przez agenta (narzędzie, parametry, wynik, czas) i oczekujące prośby o zatwierdzenie.
- Jeśli CLI pozwala, przy starcie przekaż krótką instrukcję o dostępnych narzędziach (np. `--append-system-prompt` w Claude Code).

### 5.3 Bezpieczeństwo kanału API (obowiązkowe)

1. **Most MCP:** mały plik wykonywalny `bifold-mcp` w pakiecie aplikacji. CLI uruchamia go przez stdio jako serwer MCP. Most łączy się z aplikacją przez **gniazdo Unix** i tylko przekazuje wywołania. Cała logika i polityka uprawnień są w aplikacji.
2. **Gniazdo:** `~/Library/Application Support/Bifold/run/agent.sock`, katalog z prawami `0700`, gniazdo `0600`. **Żadnych portów TCP.**
3. **Token sesji:** losowy, 256-bitowy, generowany przy uruchomieniu agenta i przekazywany tylko w zmiennej środowiskowej procesu CLI (`BIFOLD_AGENT_TOKEN`), którą most dziedziczy. Porównanie w stałym czasie, unieważnienie po zamknięciu sesji. Nigdy nie zapisuj tokenu na dysku ani w logach.
4. **Weryfikacja procesu:** aplikacja sprawdza UID procesu po drugiej stronie gniazda (`getpeereid`) oraz jego PID (`LOCAL_PEERPID`). Łańcuch procesów nadrzędnych musi prowadzić do procesu CLI, który uruchomiła aplikacja.
5. **Uprawnienia przypisane do sesji:** każda sesja ma macierz uprawnień z sekcji 6. Narzędzia z poziomem „Brak” w ogóle nie są widoczne dla agenta.
6. **Tryb ścisły (domyślnie włączony):** CLI agenta ma też własne narzędzia (powłokę, edycję plików), które omijają nasze API i jego uprawnienia. W trybie ścisłym uruchom CLI z ograniczonymi własnymi narzędziami:
   - Claude Code: dozwolone tylko narzędzia naszego serwera MCP (`--allowedTools` / `--disallowedTools`),
   - Codex: `--sandbox read-only`,
   - Antigravity: `--sandbox`,
   - Grok: ustal dostępne opcje na podstawie `--help`.

   Jeśli danego CLI nie da się ograniczyć, pokaż wyraźne ostrzeżenie w panelu agenta. Tryb pełny włączam ręcznie w ustawieniach agenta.
7. **Niezaufane dane:** treść plików, nazwy plików i odpowiedzi serwerów zwracane agentowi są oznaczone jako niezaufane dane. Uprawnienia egzekwuje aplikacja, nigdy treść promptu. Żadne dane zwrócone agentowi nie podnoszą jego uprawnień.
8. **Lista zablokowanych ścieżek** (edytowalna, domyślnie m.in. `~/.ssh`, `~/Library/Keychains`, `~/Library/Application Support/Bifold`, konfiguracja rclone, profile przeglądarek): agent nie może ich czytać ani wyświetlać w listingach.
9. **Limity:** maksymalny rozmiar odczytywanego pliku (domyślnie 2 MB, konfigurowalny), pliki binarne tylko jako metadane albo fragment w hex na wyraźne żądanie, limit liczby wywołań na minutę.

### 5.4 Poziomy dostępu

| Poziom | Znaczenie |
|---|---|
| **Brak** | Narzędzie nie istnieje dla agenta |
| **Odczyt** | Agent widzi stan lub wynik, nic nie zmienia |
| **Za zgodą** | Agent zgłasza operację. Aplikacja liczy jej skutki na sucho (dry run) i pokazuje okno zatwierdzania: lista operacji, ścieżki źródłowe i docelowe, liczba plików, rozmiar, konflikty. Ja zatwierdzam albo odrzucam |
| **Pełny** | Agent wykonuje bez pytania, ale wszystko trafia do dziennika i da się cofnąć |

**Zasada najmniejszego poziomu:** operacja dotycząca kilku zasobów dostaje najniższy poziom spośród nich. Przykład: kopiowanie z FTP (Za zgodą) na SFTP (zasób tylko do odczytu) jest dla agenta zabronione.

### 5.5 Serwery zdalne dla agenta

- Agent widzi serwery tylko pod **aliasem** (np. `prod-logi`). Nigdy nie dostaje hosta, użytkownika, portu, klucza, hasła ani ścieżki do konfiguracji.
- **SFTP, WebDAV, SMB i chmury: dla agenta tylko odczyt** (listowanie, odczyt plików, wyszukiwanie). **FTP/FTPS: zapis za zgodą.**
- Dane logowania trzymaj w Keychain. Zdalne zasoby twórz w rclone w czasie działania przez jego API (`config/create`), w pamięci procesu rclone, nigdy w pliku jawnym tekstem.
- **Agent nie ma dostępu do żadnego terminala**, ani wbudowanego, ani SSH.

### 5.6 Dziennik i cofanie działań agenta

- Każde wywołanie API zapisuje się do dziennika sesji (JSONL w `~/Library/Application Support/Bifold/agent-logs/`): czas, agent, narzędzie, parametry, decyzja przy zatwierdzaniu, wynik. W aplikacji jest przeglądarka dziennika.
- Każda operacja agenta zmieniająca pliki trafia do dziennika operacji razem z operacją odwrotną: przeniesienie z powrotem, zmiana nazwy z powrotem, przywrócenie z Kosza, usunięcie utworzonych plików, przywrócenie atrybutów i tagów.
- **„Cofnij sesję agenta”** wykonuje operacje odwrotne w odwrotnej kolejności. Wcześniej wykrywa konflikty, np. plik zmieniony od tamtej pory, i pokazuje podgląd do zatwierdzenia.

### 5.7 Narzędzia MCP (propozycja, dopracuj w ARCHITECTURE.md)

Narzędzia odpowiadają komendom z rejestru, a ich dostępność wynika z macierzy w sekcji 6. Przykłady:
`get_state`, `get_selection`, `list_directory`, `file_info`, `read_file`, `dir_size`, `checksum`, `search`, `find_duplicates`, `compare_files`, `compare_dirs`, `remote_list`, `remote_read`, `navigate`, `tab_open` / `tab_close` / `tab_switch`, `set_view`, `select` (maska), `quick_filter`, `open_preview`, `copy_paths_to_clipboard`, `color_rules_get` / `color_rules_set`, `copy`, `move`, `trash`, `mkdir`, `new_file`, `rename`, `multi_rename`, `set_attributes`, `set_tags`, `split_file`, `join_files`, `archive_create`, `archive_extract`, `sync_preview`, `sync_run`, `sync_job_save`, `undo`, `run_command` (dowolna komenda z rejestru, z jej własnym poziomem dostępu).

---

## 6. Zakres funkcji, etapy i dostęp agenta

Kolumna „Agent” to poziom dostępu z sekcji 5.4. Każdy etap kończy się działającą aplikacją.

### Etap 1: rdzeń lokalny

| Funkcja | Szczegóły | Agent |
|---|---|---|
| Dwa panele | Niezależne, przełączanie klawiszem Tab | Odczyt |
| Karty w panelach | Zapamiętywane między uruchomieniami | Pełny |
| Widoki listy | Szczegóły, lista skrócona, miniatury | Pełny |
| Widok kolumnowy | Jak w Finderze | Pełny |
| Drzewo katalogów | Obok listy plików | Odczyt |
| Konfigurowalne skróty | Domyślny profil zgodny z TC: F3 podgląd, F4 edycja, Shift+F4 nowy plik, F5 kopiuj, F6 przenieś, Shift+F6 zmień nazwę, F7 nowy katalog, F8 do Kosza, Tab zmiana panelu, Ctrl+T/W karty, Alt+F7 szukaj, Ctrl+M zmiana nazw wielu plików, Ctrl+Q szybki podgląd. MacBook nie ma klawiatury numerycznej ani klawisza Insert, więc daj zamienniki (Spacja/Shift do zaznaczania, Cmd+= i Cmd+- do zaznaczania według maski). Klawisze F1–F12 mogą wymagać klawisza fn, więc dodaj alternatywny profil oparty na Cmd | Brak |
| Szybkie wyszukiwanie i filtr | Dwa tryby: przeskok do pliku po wpisaniu liter albo filtrowanie zawartości panelu | Pełny |
| Rozmiary katalogów | Obliczanie dla zaznaczenia (Spacja) | Odczyt |
| Pasek stanu | Liczba i rozmiar zaznaczonych, wolne miejsce | Odczyt |
| Motywy i reguły kolorów | Tryb jasny i ciemny oraz **reguły kolorowania plików**: warunki (wiek, rozmiar, rozszerzenie, atrybuty, wyrażenie regularne na nazwie) → kolor lub styl. Przykład: „nazwy plików starszych niż 3 miesiące na czerwono”. Reguły zapisane jako JSON, edytowalne w ustawieniach i przez API | Pełny |
| Kopiowanie i przenoszenie w tle | Kolejka (sekcja 4.3) | Za zgodą |
| Sterowanie kolejką | Pauza, wznowienie, limit prędkości | Za zgodą |
| Usuwanie do Kosza | | Za zgodą |
| Trwałe usuwanie | Zawsze z potwierdzeniem | Brak |
| Nowy katalog (F7) | | Za zgodą |
| Nowy plik (Shift+F4) | Jak w TC: pyta o nazwę, tworzy pusty plik od razu zapisany pod tą nazwą i otwiera go w domyślnym edytorze | Za zgodą |
| Atrybuty i uprawnienia | Prawa, właściciel, daty | Za zgodą |
| Kopiowanie ścieżek i nazw | Do schowka, pojedynczo i hurtem | Pełny |
| Zaznaczanie według maski | Maski, odwracanie, zapis i odczyt zaznaczenia | Pełny |
| Cofanie operacji | Przeniesienie, zmiana nazwy, usunięcie do Kosza | Za zgodą |
| Podgląd pliku (F3) | Tekst w różnych kodowaniach, hex, obrazy | Odczyt |
| Quick Look | Spacja lub skrót | Odczyt |
| Panel podglądu | Podgląd zaznaczonego pliku w drugim panelu lub z boku | Odczyt |
| Edycja w edytorze (F4) | **Domyślnie Nextpad++** (`/Applications/Nextpad++.app`, bundle id `org.nextpadplusplus.mac`), zmienialny w ustawieniach | Brak |
| Linia poleceń pod panelami | Polecenie w bieżącym katalogu, w powłoce użytkownika (`$SHELL -lc`), wynik w wbudowanym terminalu | Brak |
| Wbudowany terminal | SwiftTerm, otwierany w bieżącym katalogu | Brak |
| Dyski i woluminy | Lista, wolne miejsce, wysuwanie | Odczyt |
| Tagi Findera | Odczyt i nadawanie | Za zgodą |
| Udostępnianie i usługi macOS | Menu Udostępnij, Otwórz za pomocą | Brak |

**Kryteria odbioru:** codzienna praca na plikach lokalnych tylko z klawiaturą. Katalog ze 100 000 plików działa płynnie. Operacje w tle da się anulować i cofnąć. Wszystkie czynności są w rejestrze komend.

### Etap 2: API agentów

| Funkcja | Szczegóły | Agent |
|---|---|---|
| Claude Code, Codex CLI, Grok CLI, Antigravity (`agy`) | Uruchamianie z aplikacji, most MCP, bezpieczeństwo z sekcji 5.3 | — |
| Panel agenta | Terminal z CLI + panel aktywności (5.2) | — |
| Okno zatwierdzania z podglądem | Dla poziomu „Za zgodą” | — |
| Dziennik działań i cofanie całej sesji agenta | Sekcja 5.6 | — |
| Stan aplikacji | Aktywny panel, ścieżki, karty, widok | Odczyt |
| Lista zaznaczonych plików | Ścieżki, rozmiary, typy | Odczyt |
| Odczyt plików lokalnych | Z limitami i listą zablokowanych ścieżek | Odczyt |
| Nawigacja i zaznaczanie | Katalogi, karty, zaznaczenie, otwieranie podglądu | Pełny |
| Wywoływanie komend aplikacji | `run_command`, z poziomem dostępu danej komendy | Za zgodą |
| Tworzenie i zapis plików | Jak Shift+F4: nazwa, pusty plik, otwarcie w edytorze | Za zgodą |

**Kryteria odbioru:** każdy z czterech agentów, uruchomiony z aplikacji, czyta zaznaczenie i nawiguje. Operacje „Za zgodą” pokazują podgląd i czekają na decyzję. Testy integracyjne potwierdzają, że:
- połączenie bez tokenu, z błędnym tokenem i z procesu spoza drzewa agenta jest odrzucane,
- narzędzia z poziomem „Brak” nie są widoczne,
- zablokowane ścieżki są niedostępne,
- cofnięcie sesji agenta przywraca stan sprzed sesji.

### Etap 3: wyszukiwanie, zmiana nazw, narzędzia plikowe

| Funkcja | Szczegóły | Agent |
|---|---|---|
| Wyszukiwanie po nazwie | Maski, wyrażenia regularne, podkatalogi | Pełny |
| Wyszukiwanie w treści | ripgrep, różne kodowania | Pełny |
| Filtry daty, rozmiaru i atrybutów | Łączone kryteria | Pełny |
| Zapisane wyszukiwania, wyniki w panelu | Wyniki jako lista do dalszych operacji | Pełny |
| Integracja ze Spotlight | | Pełny |
| Wyszukiwanie duplikatów | Nazwa, rozmiar, zawartość (hash) | Odczyt |
| Zmiana nazw wielu plików | Maski, liczniki, znajdź i zamień, wyrażenia regularne, podgląd przed wykonaniem | Za zgodą |
| Nazwy z metadanych | EXIF, tagi multimediów, daty | Za zgodą |
| Wielkość liter i rozszerzenia | Hurtowo | Za zgodą |
| Sumy kontrolne | Tworzenie i weryfikacja MD5, SHA-1, SHA-256 | Pełny |
| Dzielenie i łączenie plików | | Za zgodą |

### Etap 4: archiwa

| Funkcja | Szczegóły | Agent |
|---|---|---|
| ZIP, TAR, GZ, BZ2, XZ | Tworzenie i rozpakowywanie | Za zgodą |
| RAR i 7z | Rozpakowywanie RAR, tworzenie i rozpakowywanie 7z | Za zgodą |
| Archiwum jak katalog | Wejście, przeglądanie, kopiowanie z archiwum (`ArchiveFS`) | Odczyt |
| Archiwa z hasłem | Hasło podaję tylko ja, nigdy agent | Brak |
| Archiwa wieloczęściowe | | Za zgodą |
| Wyszukiwanie w archiwach | Bez ręcznego rozpakowywania | Pełny |

### Etap 5: sieć i serwery (rclone)

| Funkcja | Szczegóły | Agent |
|---|---|---|
| SFTP | Klucze SSH, agent SSH | **Tylko odczyt** |
| FTP i FTPS | | Za zgodą |
| WebDAV | | Odczyt |
| SMB i NFS | Przeglądanie i montowanie (NetFS) | Odczyt |
| Google Drive, Dropbox, OneDrive | Logowanie OAuth przez rclone, wykonywane przeze mnie | Odczyt |
| Menedżer połączeń | Hasła w Keychain, aliasy | Brak |
| Edycja plików zdalnych | Pobranie do pliku tymczasowego, obserwowanie zmian, wysyłka po zapisie | Brak |
| Wyszukiwanie na serwerach | `rclone lsjson` z filtrami | Odczyt |
| Kopiowanie między serwerami | Między dwoma panelami zdalnymi | Za zgodą (zgodnie z zasadą najmniejszego poziomu) |
| Odczyt plików przez SFTP dla agenta | Tylko aliasy, bez danych połączenia | Odczyt |

### Etap 6: porównywanie i synchronizacja

| Funkcja | Szczegóły | Agent |
|---|---|---|
| Porównanie zawartości plików | Tekst i binarne | Odczyt |
| Porównanie katalogów | Oznaczanie różnic w obu panelach | Odczyt |
| Synchronizacja katalogów | Jedno- i dwukierunkowa, zawsze z podglądem (dry run) | Za zgodą |
| Synchronizacja z serwerem | Lokalny ↔ zdalny | Za zgodą (zgodnie z zasadą najmniejszego poziomu) |
| Zapisane zadania synchronizacji | Uruchamiane jednym kliknięciem | Za zgodą |

### Etap 7: urządzenia i uprawnienia administratora

| Funkcja | Szczegóły | Agent |
|---|---|---|
| Telefony z Androidem (MTP) i iPhone (AFC) | Z opisanymi ograniczeniami iOS | Odczyt |
| Uprawnienia administratora | Pomocnik XPC przez `SMAppService`, wąska lista operacji, autoryzacja każdej z nich | Brak |

### Poza zakresem (nie implementuj)

Własny pasek przycisków, ulubione i historia katalogów, synchronizacja ulubionych przez iCloud, dowiązania symboliczne i twarde, bezpieczne wymazywanie, przeciąganie plików do i z innych aplikacji, Amazon S3, Backblaze B2, montowanie serwerów jako dysku, menedżer procesów, system wtyczek, własne kolumny z metadanymi, komendy użytkownika, automatyzacja (AppleScript, Skróty), wbudowany edytor tekstu.

Architektura (rejestr komend, `FileSystemProvider`) nie może jednak utrudniać dodania tych funkcji w przyszłości.

---

## 7. Czego oczekuję na start

1. `docs/ARCHITECTURE.md`: moduły (pakiety SPM), protokoły `FileSystemProvider` i `Command`, model stanu, kolejka i dziennik operacji, model uprawnień i przepływ wywołania od CLI przez most do aplikacji.
2. `docs/SECURITY.md`: model zagrożeń dla API agentów (co chroni, przed czym nie chroni, np. przed złośliwym oprogramowaniem działającym na moim koncie) i sposób testowania.
3. Szczegółowy plan Etapu 1 z listą zadań i kryteriami odbioru.
4. Lista narzędzi do zainstalowania przez Homebrew, z poleceniami.

Potem czekaj na moją akceptację.
