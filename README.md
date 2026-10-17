# Bifold

Natywny, dwupanelowy menedżer plików dla macOS 27 (Apple Silicon) w stylu Total Commandera,
obsługiwany głównie klawiaturą, z bezpiecznym API dla agentów AI (Claude Code, Codex CLI,
Grok CLI, Antigravity) przez MCP.

> Nazwa robocza. Nazwę i bundle id zmienia się w jednym miejscu: `Config/Brand.xcconfig`.

## Wymagania

- macOS 27, Apple Silicon, Xcode 27
- Homebrew i narzędzia:

```sh
# deweloperskie (generowanie projektu)
brew install xcodegen

# funkcje aplikacji (brak narzędzia wyłącza tylko zależne funkcje)
brew install ripgrep        # Etap 3: wyszukiwanie w treści (rg)
brew install sevenzip       # Etap 4: archiwa (7zz)
brew install rclone         # Etapy 5–6: serwery, chmury, synchronizacja
brew install libmtp         # Etap 7: telefony z Androidem (MTP)
brew install libimobiledevice  # Etap 7: iPhone (AFC)
```

Ścieżki narzędzi (domyślnie `/opt/homebrew/bin`) można zmienić w Ustawieniach → Narzędzia.

## Budowanie

```sh
git clone --recursive https://github.com/andrzejoles/Bifold.git
cd Bifold
make bootstrap   # buduje HexFiend.framework, generuje Bifold.xcodeproj
make test        # testy pakietu BifoldKit (143)
make test-release  # test wydajności 100 000 plików w Release (kryterium < 1 s)
make run         # buduje i uruchamia Bifold.app
```

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

## Zakres

Zaimplementowane wszystkie etapy 1–7: rdzeń lokalny, API agentów (MCP), wyszukiwanie i zmiana nazw,
archiwa (7-Zip), serwery i chmury (rclone), porównywanie i synchronizacja, urządzenia (MTP/AFC)
i pomocnik administratora. Co jest zweryfikowane testami, a co nie — [docs/STATUS.md](docs/STATUS.md).
Lista skrótów: [docs/SKROTY.md](docs/SKROTY.md).

## Dokumentacja

- [Stan realizacji i ograniczenia](docs/STATUS.md) · [Skróty](docs/SKROTY.md)
- [Architektura](docs/ARCHITECTURE.md)
- [Model zagrożeń API agentów](docs/SECURITY.md)
- [Plan Etapu 1](docs/PLAN-ETAP-1.md)
- [Decyzje](docs/DECISIONS.md) · [Biblioteki](docs/THIRD_PARTY.md) · [Zmiany](CHANGELOG.md)
- [Wymagania źródłowe](docs/PROMPT.md)
