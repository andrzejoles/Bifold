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
make test        # testy pakietu BifoldKit
make run         # buduje i uruchamia Bifold.app
```

albo `open Bifold.xcodeproj` i ⌘R. Podpis: „Sign to Run Locally” (bez zespołu, bez notaryzacji).

Przy pierwszym uruchomieniu nadaj aplikacji **Pełny dostęp do dysku**
(Ustawienia systemowe → Prywatność i ochrona → Pełny dostęp do dysku) — aplikacja sama to wykryje
i pokaże instrukcję.

## Dokumentacja

- [Architektura](docs/ARCHITECTURE.md)
- [Model zagrożeń API agentów](docs/SECURITY.md)
- [Plan Etapu 1](docs/PLAN-ETAP-1.md)
- [Decyzje](docs/DECISIONS.md) · [Biblioteki](docs/THIRD_PARTY.md) · [Zmiany](CHANGELOG.md)
- [Wymagania źródłowe](docs/PROMPT.md)
