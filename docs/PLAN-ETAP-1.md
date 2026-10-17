# Plan Etapu 1 — rdzeń lokalny

Cel: codzienna praca na plikach lokalnych wyłącznie z klawiatury. Katalog ze 100 000 plików
działa płynnie. Operacje w tle da się anulować i cofnąć. Wszystkie czynności są w rejestrze komend.

## Zadania

### 1.1 Szkielet projektu
- [ ] `project.yml` (XcodeGen), `Config/Brand.xcconfig` (nazwa i bundle id w jednym miejscu),
      `Makefile` (`bootstrap`, `generate`, `build`, `test`, `run`)
- [ ] Pakiet `BifoldKit`: `BifoldCore`, `BifoldWorkspace` + testy (Swift Testing)
- [ ] Swift 6, strict concurrency, macOS 27, arm64, bez sandboxa, podpis „Sign to Run Locally”
- [ ] `Localizable.xcstrings` (język źródłowy: polski) + skrypt sprawdzający kompletność
- [ ] Wykrywanie braku Full Disk Access + okno z instrukcją i przyciskiem do Ustawień systemowych

### 1.2 BifoldCore
- [ ] `VFSPath`, `FileItem`, `FileSystemProvider`, `ProviderRegistry`
- [ ] `LocalFS`: listowanie `getattrlistbulk` (+ zapasowo `FileManager`), FSEvents, informacje o woluminie
- [ ] `NameMask` — maski TC (`*.txt;*.md|*.bak`), wyrażenia regularne
- [ ] `ColorRule` / `ColorRuleSet` — warunki: wiek, rozmiar, rozszerzenie, atrybuty, regex; JSON
- [ ] `FileOperations`: mkdir, nowy plik, zmiana nazwy, Kosz (z nową ścieżką), trwałe usuwanie,
      atrybuty (prawa, właściciel, daty), tagi Findera
- [ ] `OperationQueue` + `FileJob`: kopiowanie/przenoszenie (`copyfile` z callbackiem), pauza,
      wznowienie, anulowanie, limit prędkości, konflikty (nadpisz/pomiń/zmień nazwę/dla wszystkich)
- [ ] `OperationJournal` (JSONL) + `UndoPlanner` (wykrywanie konfliktów przed cofnięciem)
- [ ] `DirectorySizer` (równolegle, anulowalne), `VolumeList` (lista, wolne miejsce, wysuwanie)
- [ ] `TextDecoding` — wykrywanie i zmiana kodowania dla podglądu

### 1.3 BifoldWorkspace
- [ ] `Workspace`, `Panel`, `Tab` (`@Observable`, `@MainActor`), `SessionStore` (karty między uruchomieniami)
- [ ] `ListingProcessor` — sortowanie i filtrowanie w tle
- [ ] `CommandRegistry`, `CommandDescriptor`, `AgentAccess`, `EffectPreview`
- [ ] Komendy Etapu 1 (lista niżej) z poziomami agenta z macierzy
- [ ] `Keymap` + profile `totalCommander` i `command`, zapis/odczyt nadpisań
- [ ] `SelectionStore` — zapis i odczyt zaznaczenia

### 1.4 Interfejs
- [ ] Okno główne: dwa panele, Tab zmienia panel, aktywny panel wyróżniony
- [ ] Karty (Ctrl+T / Ctrl+W, Ctrl+Tab), zapamiętywane
- [ ] Widoki: szczegóły (`NSTableView`), lista skrócona, miniatury (`NSCollectionView`), kolumnowy (`NSBrowser`)
- [ ] Drzewo katalogów (`NSOutlineView`) obok listy
- [ ] Szybkie wyszukiwanie (przeskok po literach) i filtr panelu
- [ ] Pasek stanu (zaznaczone: liczba, rozmiar; wolne miejsce), rozmiary katalogów (Spacja)
- [ ] Motyw jasny/ciemny/systemowy, reguły kolorów stosowane w listach
- [ ] Pasek kolejki operacji: postęp, pauza, wznowienie, anulowanie, limit prędkości
- [ ] Okna dialogowe: nazwa (F7, Shift+F4, Shift+F6), potwierdzenie kopiowania/przenoszenia z celem,
      konflikt, trwałe usuwanie, atrybuty, maska zaznaczenia
- [ ] Podgląd F3 (tekst + kodowania, hex HexFiend, obrazy), Quick Look, panel podglądu
- [ ] F4 w edytorze (domyślnie Nextpad++), Shift+F4 nowy plik i otwarcie
- [ ] Linia poleceń pod panelami → `$SHELL -lc` w terminalu SwiftTerm; wbudowany terminal
- [ ] Dyski i woluminy (menu z listą, wolne miejsce, wysuwanie)
- [ ] Tagi Findera (odczyt w kolumnie, nadawanie w oknie)
- [ ] Menu Udostępnij, Otwórz za pomocą
- [ ] Paleta komend (Cmd+Shift+P) — wszystkie komendy z rejestru
- [ ] Ustawienia (SwiftUI): ogólne, skróty, reguły kolorów (JSON + edytor), narzędzia, agent (limity)

## Komendy Etapu 1

| Id | Skrót TC | Skrót Cmd | Agent |
|---|---|---|---|
| `panel.switch` | Tab | Tab | odczyt |
| `panel.navigate`, `panel.up`, `panel.open` | Enter, Backspace | Cmd+↓, Cmd+↑ | pełny |
| `panel.back`, `panel.forward` | Alt+←/→ | Cmd+[ / Cmd+] | pełny |
| `panel.refresh` | Ctrl+R | Cmd+R | pełny |
| `panel.otherToSame` | Alt+= | — | pełny |
| `tab.new`, `tab.close`, `tab.next`, `tab.previous`, `tab.select` | Ctrl+T, Ctrl+W, Ctrl+Tab, Ctrl+Shift+Tab | Cmd+T, Cmd+W | pełny |
| `view.details`, `view.brief`, `view.thumbnails`, `view.columns` | Ctrl+1…4 | Cmd+1…4 | pełny |
| `view.toggleTree` | Ctrl+Shift+T | Cmd+Opt+T | odczyt |
| `view.previewPanel` | Ctrl+Q | Cmd+Opt+P | odczyt |
| `view.quickLook` | Cmd+Y | Cmd+Y | odczyt |
| `view.toggleHidden` | Ctrl+H | Cmd+Shift+. | pełny |
| `view.sortBy*` | Ctrl+F3…F6 | — | pełny |
| `panel.quickSearch`, `panel.quickFilter` | litery / Ctrl+S | litery / Cmd+F | pełny |
| `selection.toggle` | Spacja / Shift+↑↓ | jw. | pełny |
| `selection.byMask`, `selection.deselectByMask`, `selection.invert`, `selection.all`, `selection.none` | Cmd+=, Cmd+-, Cmd+*, Cmd+A, Cmd+Shift+A | jw. | pełny |
| `selection.save`, `selection.restore` | — | — | pełny |
| `selection.calculateSizes` | Spacja na katalogu | jw. | odczyt |
| `file.view` | F3 | Opt+Spacja | odczyt |
| `file.edit` | F4 | Cmd+E | brak |
| `file.newFile` | Shift+F4 | Cmd+Shift+N | za zgodą |
| `file.copy` | F5 | Cmd+Shift+C | za zgodą |
| `file.move` | F6 | Cmd+Shift+M | za zgodą |
| `file.rename` | Shift+F6 | Cmd+Shift+R | za zgodą |
| `file.mkdir` | F7 | Cmd+N | za zgodą |
| `file.trash` | F8 | Cmd+⌫ | za zgodą |
| `file.deletePermanently` | Shift+F8 | Cmd+Opt+⌫ | brak |
| `file.attributes` | Opt+A | Cmd+I | za zgodą |
| `file.tags` | — | Cmd+Opt+G | za zgodą |
| `clipboard.copyPaths`, `clipboard.copyNames` | Ctrl+Shift+C, Ctrl+Shift+N | Cmd+Opt+C | pełny |
| `edit.undo` | Cmd+Z | Cmd+Z | za zgodą |
| `queue.pauseAll`, `queue.resumeAll`, `queue.cancel`, `queue.setSpeedLimit` | — | — | za zgodą |
| `colors.get`, `colors.set` | — | — | pełny |
| `tools.terminal` | Ctrl+` | Ctrl+` | brak |
| `tools.commandLine` | Ctrl+E (fokus) | Cmd+L | brak |
| `tools.volumes`, `volume.eject` | Alt+F1 / Alt+F2 | Cmd+D | odczyt |
| `tools.share`, `tools.openWith` | — | — | brak |
| `tools.commandPalette` | Cmd+Shift+P | Cmd+Shift+P | brak |

Dokładna, aktualna lista skrótów jest generowana z rejestru: `docs/SKROTY.md` (`make docs`).

## Kryteria odbioru Etapu 1

1. Wszystkie czynności z tabeli są dostępne z klawiatury i z palety komend; menu jest budowane z rejestru.
2. Katalog testowy ze 100 000 plików (`make perf-fixture`): pierwsze wyświetlenie < 1 s
   (test wydajnościowy `LocalFSPerformanceTests` mierzy listowanie + sortowanie), przewijanie płynne.
3. Kopiowanie dużego pliku w tle można wstrzymać, wznowić, ograniczyć prędkość i anulować;
   po anulowaniu nie zostaje częściowy plik docelowy.
4. Przeniesienie, zmiana nazwy i usunięcie do Kosza dają się cofnąć (Cmd+Z), z wykrywaniem konfliktów.
5. Karty, widoki i ścieżki przywracają się po ponownym uruchomieniu.
6. Testy jednostkowe: maski, reguły kolorów, operacje na plikach, kolejka (pauza/anulowanie/konflikty),
   dziennik i cofanie, sortowanie/filtrowanie, rejestr komend (każda komenda ma poziom agenta i opis skutków).
7. `make test` i `make build` przechodzą bez błędów i ostrzeżeń współbieżności.
