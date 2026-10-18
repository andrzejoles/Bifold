# Bifold

Natywny, dwupanelowy menedżer plików dla macOS 27 (Apple Silicon) w stylu Total Commandera,
obsługiwany głównie klawiaturą, z bezpiecznym API dla agentów AI (Claude Code, Codex CLI,
Grok CLI, Antigravity) przez MCP.

**Autor:** Andrzej Oleś w kooperacji z Claude AI · **Licencja:** [MIT](LICENSE)

> Nazwa robocza. Nazwę i bundle id zmienia się w jednym miejscu: `Config/Brand.xcconfig`.

## Instalacja (gotowa aplikacja)

1. Pobierz `Bifold-X.Y.Z.dmg` z [Wydań](https://github.com/andrzejoles/Bifold/releases/latest)
   i przeciągnij aplikację do Aplikacji (albo uruchom `Bifold-X.Y.Z.pkg`).
2. Aplikacja nie jest notaryzowana przez Apple: przy pierwszym uruchomieniu macOS ją zablokuje —
   Ustawienia systemowe → Prywatność i ochrona → „Otwórz mimo to”
   (albo `xattr -dr com.apple.quarantine /Applications/Bifold.app`).
3. Zainstaluj narzędzia (niżej) i nadaj Pełny dostęp do dysku — aplikacja pokaże, jak.

**Aktualizacje są automatyczne:** raz dziennie aplikacja sprawdza nowe wydanie, pobiera je w tle
i instaluje przy zamknięciu (menu Bifold → „Sprawdź uaktualnienia…” robi to od razu). Każde wydanie
jest podpisane kluczem autora (EdDSA, Sparkle), więc aplikacja nie przyjmie pliku z innego źródła.
Aplikacja ma stały podpis, dlatego Pełny dostęp do dysku i dostęp do haseł w Pęku kluczy zostają
po aktualizacji.

**Wersja** liczona jest z historii gita jak w CantatePresenter: `1 + PR/10 . PR mod 10 . commity od
ostatniego PR` (`make version`); numer kompilacji to liczba commitów.

## Wymagania

- macOS 27, Apple Silicon, Xcode 27
- Homebrew i narzędzia:

```sh
# deweloperskie (generowanie projektu)
brew install xcodegen

# funkcje aplikacji (brak narzędzia wyłącza tylko zależne funkcje)
brew install ripgrep        # Etap 3: wyszukiwanie w treści (rg)
brew install sevenzip       # Etap 4: archiwa (7zz)
brew install rclone         # Etapy 5–6: serwery SFTP/FTP/WebDAV, chmury, synchronizacja
                            # (SCP używa systemowych ssh/scp — bez dodatkowych narzędzi)
brew install libmtp         # Etap 7: telefony z Androidem (MTP)
brew install libimobiledevice  # Etap 7: iPhone (AFC)
```

Ścieżki narzędzi (domyślnie `/opt/homebrew/bin`) można zmienić w Ustawieniach → Narzędzia.

## Budowanie

```sh
git clone --recursive https://github.com/andrzejoles/Bifold.git
cd Bifold
make bootstrap   # buduje HexFiend.framework, generuje Bifold.xcodeproj
make test        # testy pakietu BifoldKit
make test-release  # test wydajności 100 000 plików w Release (kryterium < 1 s)
make run         # buduje i uruchamia Bifold.app
make installer   # dist/Bifold-X.Y.Z.dmg i .pkg (podpis: scripts/signing.sh)
```

Wydania (instalatory, kanał aktualizacji, szkic na GitHubie): [docs/WYDANIA.md](docs/WYDANIA.md).

albo `open Bifold.xcodeproj` i ⌘R. Podpis: „Sign to Run Locally” (bez zespołu, bez notaryzacji).
Przy pierwszym budowaniu w Xcode zaakceptuj wtyczkę budowania SwiftTerm („Trust & Enable”).
Pomocnik administratora wymaga podpisu z zespołem — patrz `Config/Brand.xcconfig`.

Przy pierwszym uruchomieniu nadaj aplikacji **Pełny dostęp do dysku**
(Ustawienia systemowe → Prywatność i ochrona → Pełny dostęp do dysku) — aplikacja sama to wykryje
i pokaże instrukcję.

## Agenci AI

Menu **Agent** (albo Ctrl+Alt+1…4) uruchamia Claude Code, Codex CLI, Grok CLI lub Antigravity w panelu
agenta, z katalogiem roboczym aktywnego panelu. CLI dostaje serwer MCP „bifold” tylko na tę sesję
(Antigravity — jednorazowa rejestracja za zgodą). Operacje na plikach agent tylko zgłasza — Bifold
pokazuje podgląd i czeka na „Zatwierdź”. Wszystko jest w dzienniku (Agent → Dziennik agentów) i da się
cofnąć (Agent → Cofnij sesję agenta). Szczegóły: [SECURITY.md](docs/SECURITY.md).

Test z prawdziwymi CLI (zużywa limit subskrypcji):

```sh
cd Packages/BifoldKit && BIFOLD_E2E_AGENTS=1 swift test --filter AgentE2ETests
```

## Język interfejsu

Polski (źródłowy), angielski, niemiecki, hiszpański i ukraiński. Domyślnie jak w systemie; zmiana
w Ustawieniach → Ogólne → Język interfejsu (działa po ponownym uruchomieniu). Jak w CantatePresenter:
„Eksportuj plik do tłumaczenia…” zapisuje wszystkie teksty do pliku JSON (polski tekst, angielska
podpowiedź, instrukcja dla AI), a „Importuj tłumaczenie…” dodaje gotowy język — bez przebudowy
aplikacji. Eksport w wybranym języku pozwala poprawić istniejące tłumaczenie. Teksty z niezgodnymi
znacznikami wartości (`%@`, `%lld`) są przy imporcie pomijane.

## Serwery: SFTP, SCP i stare systemy (np. AIX 6.1)

Połączenia (⌘K / Ctrl+F): otwieranie ⇧⌘K, **rozłączanie Ctrl+Shift+F / ⌃⌘K** albo ⏏ na pasku ścieżki. SFTP, **SCP**, FTP/FTPS, WebDAV, SMB, Google Drive, Dropbox, OneDrive.
Adres, port, użytkownik i katalog są w `~/Library/Application Support/Bifold/connections.json`
(uprawnienia 0600), hasła, hasła kluczy i tokeny wyłącznie w Pęku kluczy macOS. Agent AI zna tylko alias.

- **SCP** — klasyczny protokół (`scp -O`) i polecenia powłoki przez SSH, dla serwerów bez SFTP.
  Kopiowanie w obie strony (F5), nowy katalog, zmiana nazwy, usuwanie, podgląd i edycja plików.
  Kodowanie nazw na serwerze: UTF-8 albo ISO-8859-2.
- **Zgodność ze starymi serwerami** (SFTP i SCP) — włącza algorytmy, których nowy OpenSSH domyślnie
  nie używa: `diffie-hellman-group1/14-sha1`, klucze `ssh-rsa`, szyfry CBC. Potrzebne m.in. dla AIX 6.1.
  Klucze DSA nie są obsługiwane (OpenSSH 10 je usunął) — serwer musi mieć klucz RSA.
- **Terminal SSH w panelu:** otwarcie połączenia SFTP/SCP pokazuje w drugim panelu terminal zalogowany na
  serwer (przez to samo połączenie, bez ponownego hasła). Klawisze bez Cmd idą do serwera, Ctrl+Tab wraca
  do drugiego panelu, ⌘W zamyka kartę. Można to wyłączyć w ustawieniach połączenia.
- Klucz serwera jest zapamiętywany w `~/.ssh/known_hosts` przy pierwszym połączeniu i sprawdzany przy
  następnych; zmieniony klucz (możliwy podstawiony serwer) blokuje połączenie.

## Zakres

Zaimplementowane wszystkie etapy 1–7: rdzeń lokalny, API agentów (MCP), wyszukiwanie i zmiana nazw,
archiwa (7-Zip), serwery i chmury (rclone), porównywanie i synchronizacja, urządzenia (MTP/AFC)
i pomocnik administratora. Co jest zweryfikowane testami, a co nie — [docs/STATUS.md](docs/STATUS.md).
Lista skrótów: [docs/SKROTY.md](docs/SKROTY.md).

## Dokumentacja

- [Stan realizacji i ograniczenia](docs/STATUS.md) · [Skróty](docs/SKROTY.md) · [Wydania](docs/WYDANIA.md)
- [Architektura](docs/ARCHITECTURE.md)
- [Model zagrożeń API agentów](docs/SECURITY.md)
- [Plan Etapu 1](docs/PLAN-ETAP-1.md)
- [Decyzje](docs/DECISIONS.md) · [Biblioteki](docs/THIRD_PARTY.md) · [Zmiany](CHANGELOG.md)
- [Wymagania źródłowe](docs/PROMPT.md)
