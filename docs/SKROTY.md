# Skróty i komendy

Wygenerowane z rejestru komend (`BIFOLD_WRITE_DOCS=1 swift test --filter DocsGenerator`).
Komendy dodawane przez aplikację (agenci, pomocnik administratora) są w palecie komend (⇧⌘P).
Poziom agenta: Brak — narzędzie niewidoczne; Odczyt; Za zgodą — okno zatwierdzania; Pełny.

## Panel

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Przełącz panel | `panel.switch` | ⇥ | ⇥ | Odczyt |
| Otwórz | `panel.open` | ↩ | ↩ ⌘↓ | Brak |
| Przejdź do katalogu… | `panel.navigate` | ⇧⌘G | ⇧⌘G | Pełny |
| Katalog nadrzędny | `panel.up` | ⌫ ⌃⇞ | ⌘↑ ⌫ ⌃⇞ | Pełny |
| Katalog główny | `panel.root` | ⌃\ | ⌘\ ⌃\ | Pełny |
| Katalog domowy | `panel.home` | ⇧⌘H | ⇧⌘H | Pełny |
| Wstecz | `panel.back` | ⌥← | ⌘[ ⌥← | Pełny |
| Dalej | `panel.forward` | ⌥→ | ⌘] ⌥→ | Pełny |
| Odśwież | `panel.refresh` | ⌃R | ⌘R ⌃R | Pełny |
| Ten sam katalog w drugim panelu | `panel.otherToSame` | ⌃= | ⌃= ⌥⌘= | Pełny |
| Otwórz w drugim panelu | `panel.openInOther` | ⌃⇧→ | ⌥⌘→ ⌃⇧→ | Pełny |
| Zamień panele | `panel.swap` | ⌃U | ⌘U ⌃U | Pełny |
| Filtr panelu | `panel.quickFilter` | ⌃S | ⌘F ⌃S | Pełny |
| Szybkie wyszukiwanie | `panel.quickSearch` |  |  | Pełny |
| Ustaw kursor | `panel.setCursor` |  |  | Pełny |

## Karty

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Nowa karta | `tab.new` | ⌃T | ⌘T ⌃T | Pełny |
| Zamknij kartę | `tab.close` | ⌃W | ⌘W ⌃W | Pełny |
| Następna karta | `tab.next` | ⌃⇥ | ⌃⇥ ⇧⌘] | Pełny |
| Poprzednia karta | `tab.previous` | ⌃⇧⇥ | ⇧⌘[ ⌃⇧⇥ | Pełny |
| Wybierz kartę | `tab.select` |  |  | Pełny |

## Widok

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Szczegóły | `view.details` | ⌃1 | ⌃1 | Pełny |
| Lista skrócona | `view.brief` | ⌃2 | ⌃2 | Pełny |
| Miniatury | `view.thumbnails` | ⌃3 | ⌃3 | Pełny |
| Kolumny | `view.columns` | ⌃4 | ⌃4 | Pełny |
| Ustaw widok | `view.setMode` |  |  | Pełny |
| Sortuj: Nazwa | `view.sortBy.name` | ⌃F3 | ⌃F3 ⌃⌘1 | Pełny |
| Sortuj: Rozszerzenie | `view.sortBy.ext` | ⌃F4 | ⌃F4 ⌃⌘2 | Pełny |
| Sortuj: Data modyfikacji | `view.sortBy.modified` | ⌃F5 | ⌃F5 ⌃⌘3 | Pełny |
| Sortuj: Rozmiar | `view.sortBy.size` | ⌃F6 | ⌃F6 ⌃⌘4 | Pełny |
| Sortuj: Data utworzenia | `view.sortBy.created` | ⌃F7 | ⌃F7 ⌃⌘5 | Pełny |
| Sortuj | `view.sortBy` |  |  | Pełny |
| Drzewo katalogów | `view.toggleTree` | ⌃⇧T | ⌥⌘T ⌃⇧T | Odczyt |
| Panel podglądu | `view.previewPanel` | ⌃Q | ⌃Q ⌥⌘P | Odczyt |
| Quick Look | `view.quickLook` | ⌘Y | ⌘Y | Odczyt |
| Pokaż pliki ukryte | `view.toggleHidden` | ⌃H ⇧⌘. | ⌃H ⇧⌘. | Pełny |
| Reguły kolorów (JSON) | `colors.get` |  |  | Pełny |
| Ustaw reguły kolorów | `colors.set` |  |  | Pełny |

## Zaznaczanie

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Zaznacz / odznacz | `selection.toggle` | Spacja | Spacja | Pełny |
| Zaznacz i w górę | `selection.toggleUp` | ⇧↑ | ⇧↑ | Pełny |
| Zaznacz i w dół | `selection.toggleDown` | ⇧↓ | ⇧↓ | Pełny |
| Zaznacz według maski… | `selection.byMask` | ⌘= | ⌘= | Pełny |
| Odznacz według maski… | `selection.deselectByMask` | ⌘- | ⌘- | Pełny |
| Odwróć zaznaczenie | `selection.invert` | ⇧⌘8 | ⇧⌘8 | Pełny |
| Zaznacz wszystko | `selection.all` | ⌘A | ⌘A | Pełny |
| Odznacz wszystko | `selection.none` | ⇧⌘A | ⇧⌘A | Pełny |
| Zaznacz pliki z tym samym rozszerzeniem | `selection.sameExtension` | ⌥= | ⌥= ⌥⇧⌘= | Pełny |
| Ustaw zaznaczenie | `selection.set` |  |  | Pełny |
| Zapamiętaj zaznaczenie | `selection.save` |  |  | Pełny |
| Przywróć zaznaczenie | `selection.restore` |  |  | Pełny |
| Zapisz zaznaczenie do pliku… | `selection.saveToFile` |  |  | Pełny |
| Wczytaj zaznaczenie z pliku… | `selection.loadFromFile` |  |  | Pełny |
| Oblicz rozmiary katalogów | `selection.calculateSizes` | ⌥⇧↩ | ⌥⌘↩ ⌥⇧↩ | Odczyt |
| Porównaj katalogi | `dirs.compare` | ⇧F2 | ⇧F2 ⌥⇧⌘D | Odczyt |

## Plik

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Podgląd | `file.view` | F3 | F3 ⌘3 ⌥Spacja | Odczyt |
| Edytuj | `file.edit` | F4 | F4 ⌘4 ⌘E | Brak |
| Nowy plik… | `file.newFile` | ⇧F4 | ⇧F4 ⌥⌘N | Za zgodą |
| Kopiuj… | `file.copy` | F5 | F5 ⌘5 | Za zgodą |
| Przenieś… | `file.move` | F6 | F6 ⌘6 | Za zgodą |
| Zmień nazwę… | `file.rename` | ⇧F6 | ⇧F6 ⇧⌘R | Za zgodą |
| Nowy katalog… | `file.mkdir` | F7 | F7 ⌘7 ⇧⌘N | Za zgodą |
| Przenieś do Kosza | `file.trash` | F8 ⌦ | F8 ⌘8 ⌦ ⌘⌫ | Za zgodą |
| Usuń trwale… | `file.deletePermanently` | ⇧F8 ⇧⌦ | ⇧F8 ⇧⌦ ⌥⌘⌫ | Brak |
| Atrybuty i uprawnienia… | `file.attributes` | ⌃⌥A | ⌘I ⌃⌥A | Za zgodą |
| Tagi Findera… | `file.tags` | ⌃⌥G | ⌥⌘G ⌃⌥G | Za zgodą |
| Zmiana nazw wielu plików… | `file.multiRename` | ⌃M | ⌃M ⇧⌘M | Za zgodą |
| Utwórz sumy kontrolne… | `file.checksumCreate` | ⌥⌘K | ⌥⌘K | Pełny |
| Sprawdź sumy kontrolne | `file.checksumVerify` | ⌥⇧⌘K | ⌥⇧⌘K | Pełny |
| Podziel plik… | `file.split` | ⌥⇧⌘S | ⌥⇧⌘S | Za zgodą |
| Połącz pliki… | `file.join` | ⌥⇧⌘J | ⌥⇧⌘J | Za zgodą |
| Spakuj… | `archive.create` | ⌥F5 | ⌥F5 ⌥⌘5 | Za zgodą |
| Rozpakuj… | `archive.extract` | ⌥F9 | ⌥F9 ⌥⌘9 | Za zgodą |
| Testuj archiwum | `archive.test` | ⌥⇧⌘T | ⌥⇧⌘T | Odczyt |
| Zawartość archiwum | `archive.list` |  |  | Odczyt |
| Porównaj pliki | `file.compare` | ⌃⇧F2 | ⌃⇧F2 ⌥⇧⌘F2 | Odczyt |

## Schowek

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Kopiuj ścieżki | `clipboard.copyPaths` | ⌥⌘C | ⌥⌘C | Pełny |
| Kopiuj nazwy | `clipboard.copyNames` | ⌃⌥C | ⌃⌥C | Pełny |
| Kopiuj ścieżkę katalogu | `clipboard.copyDirectory` | ⌃⌥⇧C | ⌃⌥⇧C | Pełny |

## Edycja

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Cofnij operację | `edit.undo` | ⌘Z | ⌘Z | Za zgodą |
| Dziennik operacji | `edit.journal` | ⌥⌘J | ⌥⌘J | Brak |

## Kolejka

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Wstrzymaj operacje | `queue.pause` |  |  | Za zgodą |
| Wznów operacje | `queue.resume` |  |  | Za zgodą |
| Anuluj operacje | `queue.cancel` |  |  | Za zgodą |
| Limit prędkości… | `queue.setSpeedLimit` |  |  | Za zgodą |
| Lista zadań | `queue.list` |  |  | Odczyt |
| Usuń zakończone z listy | `queue.clearFinished` |  |  | Pełny |

## Narzędzia

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Szukaj plików… | `search.find` | ⌥F7 | ⌥F7 ⌥⌘F | Pełny |
| Szukaj w Spotlight… | `search.spotlight` | ⌥⌘Spacja | ⌥⌘Spacja | Pełny |
| Zapisz wyszukiwanie | `search.save` |  |  | Pełny |
| Uruchom zapisane wyszukiwanie… | `search.runSaved` |  |  | Pełny |
| Zapisane wyszukiwania | `search.listSaved` |  |  | Odczyt |
| Szukaj duplikatów… | `search.duplicates` | ⌥⌘D | ⌥⌘D | Odczyt |
| Podgląd synchronizacji | `sync.preview` |  |  | Odczyt |
| Synchronizuj katalogi… | `sync.run` | ⌃⌥S | ⌃⌥S ⌥⇧⌘Y | Za zgodą |
| Zapisz zadanie synchronizacji | `sync.save` |  |  | Za zgodą |
| Zapisane zadania synchronizacji | `sync.listSaved` |  |  | Odczyt |
| Uruchom zadanie synchronizacji… | `sync.runSaved` |  |  | Za zgodą |
| Paleta komend… | `tools.commandPalette` | ⇧⌘P | ⇧⌘P | Brak |
| Terminal | `tools.terminal` | ⌃` | ⌃` | Brak |
| Linia poleceń | `tools.commandLine` | ⌘L | ⌘L | Brak |
| Uruchom polecenie | `tools.runCommand` |  |  | Brak |
| Dyski i woluminy… | `tools.volumes` | ⌥F1 | ⌘D ⌥F1 | Odczyt |
| Wysuń wolumin | `volume.eject` | ⌥⌘E | ⌥⌘E | Brak |
| Udostępnij… | `tools.share` | ⌥⌘S | ⌥⌘S | Brak |
| Otwórz za pomocą… | `tools.openWith` | ⌥⌘O | ⌥⌘O | Brak |
| Pokaż w Finderze | `tools.revealInFinder` | ⌥⌘R | ⌥⌘R | Brak |
| Ustawienia… | `tools.settings` | ⌘, | ⌘, | Brak |
| Przełącz profil skrótów (F-klawisze / Cmd) | `tools.switchShortcutProfile` |  |  | Brak |

## Sieć

| Komenda | Id | Profil TC | Profil Cmd | Agent |
|---|---|---|---|---|
| Menedżer połączeń… | `remote.connections` | ⌃F | ⌘K ⌃F | Brak |
| Terminal SSH… | `remote.terminal` |  |  | Brak |
| Rozłącz | `remote.disconnect` | ⌃⇧F | ⌃⌘K ⌃⇧F | Odczyt |
| Otwórz połączenie… | `remote.open` |  | ⇧⌘K | Odczyt |
| Lista połączeń | `remote.listConnections` |  |  | Odczyt |
| Zawartość katalogu na serwerze | `remote.list` |  |  | Odczyt |
| Odczyt pliku z serwera | `remote.read` |  |  | Odczyt |
| Szukaj na serwerze… | `remote.search` |  |  | Odczyt |
| Edytuj plik zdalny | `remote.edit` |  |  | Brak |
| Zamontuj udział SMB/NFS… | `remote.mount` |  |  | Brak |
| Podłączone urządzenia | `device.list` |  |  | Odczyt |
| Otwórz urządzenie (telefon)… | `device.open` | ⌃⌥P | ⌃⌥P | Odczyt |

