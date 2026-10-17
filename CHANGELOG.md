# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/).

## [Unreleased]

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
