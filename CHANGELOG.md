# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/).

## [Unreleased]

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
